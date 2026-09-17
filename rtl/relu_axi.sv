// =============================================================================
// relu_axi
// The Leaky ReLU accelerator: relu_unit made addressable by the PS.
//
// The second implementation of docs/accelerator-contract.md, and deliberately
// the other shape from sparse_cnn_axi. It transforms a tile beat by beat rather
// than reducing it, so it carries the contract's optional AXI4-Stream master
// and the block design gives it the DMA's S2MM channel. Its AXI4-Lite slave
// holds a writable parameter rather than only results, which is the direction
// the first accelerator never exercises.
//
// Register map (byte offsets, 32-bit words) — see docs/register-map-relu.md:
//   0x00  ID      RO  {"RL", major, minor}
//   0x04  CTRL    RW  [0] EN (level, reset 1)
//   0x08  STATUS  RO  [0] BUSY [1] DONE
//   0x0C  SLOPE   RW  [7:0] negative slope, unsigned Q0.8
//   0x10  COUNT   RO  beats in the last completed tile
//
// Only offset 0x00 is the contract's. CTRL's layout is this design's own and
// is not sparse_cnn_axi's: there is no tile to start, because a tile begins
// when its first beat arrives.
//
// Single clock domain: everything runs on aclk, the PL clock sourced by the PS.
// =============================================================================
module relu_axi #(
    // Activation width. It drives both stream ports' widths, so it has to be a
    // parameter and its default has to be a literal — IP Integrator evaluates a
    // module header with no visibility of any package. The elaboration check
    // below is what keeps the literal honest.
    parameter int unsigned DATA_W = 8,

    // The control interface's own widths, fixed by the accelerator contract and
    // restated here for the same reason.
    parameter int unsigned AXIL_DATA_W = 32,
    parameter int unsigned AXIL_ADDR_W = 8
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi:s_axis:m_axis, ASSOCIATED_RESET aresetn" *)
    input logic aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input logic aresetn,

    // --- AXI4-Lite slave: control, status and the slope ---
    input  logic [  AXIL_ADDR_W-1:0] s_axi_awaddr,
    input  logic [              2:0] s_axi_awprot,
    input  logic                     s_axi_awvalid,
    output logic                     s_axi_awready,
    input  logic [  AXIL_DATA_W-1:0] s_axi_wdata,
    input  logic [AXIL_DATA_W/8-1:0] s_axi_wstrb,
    input  logic                     s_axi_wvalid,
    output logic                     s_axi_wready,
    output logic [              1:0] s_axi_bresp,
    output logic                     s_axi_bvalid,
    input  logic                     s_axi_bready,
    input  logic [  AXIL_ADDR_W-1:0] s_axi_araddr,
    input  logic [              2:0] s_axi_arprot,
    input  logic                     s_axi_arvalid,
    output logic                     s_axi_arready,
    output logic [  AXIL_DATA_W-1:0] s_axi_rdata,
    output logic [              1:0] s_axi_rresp,
    output logic                     s_axi_rvalid,
    input  logic                     s_axi_rready,

    // --- AXI4-Stream slave: one activation per beat ---
    input  logic [DATA_W-1:0] s_axis_tdata,
    input  logic              s_axis_tvalid,
    output logic              s_axis_tready,
    input  logic              s_axis_tlast,

    // --- AXI4-Stream master: one activation per beat, same order ---
    output logic [DATA_W-1:0] m_axis_tdata,
    output logic              m_axis_tvalid,
    input  logic              m_axis_tready,
    output logic              m_axis_tlast
);

  if (DATA_W != relu_pkg::DATA_W) begin : gen_data_w_check
    $error("DATA_W (%0d) does not match relu_pkg::DATA_W (%0d)", DATA_W, relu_pkg::DATA_W);
  end

  if (AXIL_DATA_W != accel_contract_pkg::AXIL_DATA_W) begin : gen_axil_data_w_check
    $error(
        "AXIL_DATA_W (%0d) does not match the accelerator contract (%0d)",
        AXIL_DATA_W,
        accel_contract_pkg::AXIL_DATA_W
    );
  end

  if (AXIL_ADDR_W != accel_contract_pkg::AXIL_ADDR_W) begin : gen_axil_addr_w_check
    $error(
        "AXIL_ADDR_W (%0d) does not match the accelerator contract (%0d)",
        AXIL_ADDR_W,
        accel_contract_pkg::AXIL_ADDR_W
    );
  end

  localparam int unsigned SlopeW = relu_pkg::SLOPE_W;
  localparam int unsigned CountW = relu_pkg::COUNT_W;
  localparam int unsigned StrbW = AXIL_DATA_W / 8;

  localparam logic [AXIL_ADDR_W-1:0] RegId = AXIL_ADDR_W'(accel_contract_pkg::REG_ID_OFFSET);
  localparam logic [AXIL_ADDR_W-1:0] RegCtrl = 'h04;
  localparam logic [AXIL_ADDR_W-1:0] RegStatus = 'h08;
  localparam logic [AXIL_ADDR_W-1:0] RegSlope = 'h0C;
  localparam logic [AXIL_ADDR_W-1:0] RegCount = 'h10;

  localparam int unsigned CtrlEn = 0;
  localparam int unsigned StatusBusy = 0;
  localparam int unsigned StatusDone = 1;

  // "RL", then major, minor. The tag is this design's; the layout is the
  // contract's.
  localparam logic [31:0] IdValue = accel_contract_pkg::id_value(16'h524C, 8'd1, 8'd0);

  localparam logic [AXIL_DATA_W-1:0] CtrlReset = AXIL_DATA_W'(1) << CtrlEn;
  localparam logic [AXIL_DATA_W-1:0] CtrlMask = AXIL_DATA_W'(1) << CtrlEn;
  localparam logic [AXIL_DATA_W-1:0] SlopeMask = (AXIL_DATA_W'(1) << SlopeW) - 1;

  logic [AXIL_DATA_W-1:0] ctrl_reg;
  logic [     SlopeW-1:0] slope_reg;
  logic                   en_reg;
  assign en_reg = ctrl_reg[CtrlEn];

  // ---------------------------------------------------------------------------
  // AXI4-Lite write channel. Address and data are captured independently and
  // applied together, so neither ready is derived from its own valid.
  // ---------------------------------------------------------------------------
  logic aw_pend, w_pend, bvalid_q;
  logic [AXIL_ADDR_W-1:0] aw_addr_q;
  logic [AXIL_DATA_W-1:0] w_data_q;
  logic [      StrbW-1:0] w_strb_q;

  assign s_axi_awready = !aw_pend && !bvalid_q;
  assign s_axi_wready  = !w_pend && !bvalid_q;
  assign s_axi_bvalid  = bvalid_q;
  assign s_axi_bresp   = 2'b00;

  logic aw_fire, w_fire, wr_commit;
  assign aw_fire   = s_axi_awvalid && s_axi_awready;
  assign w_fire    = s_axi_wvalid && s_axi_wready;
  assign wr_commit = (aw_pend || aw_fire) && (w_pend || w_fire);

  logic [AXIL_ADDR_W-1:0] wr_addr;
  logic [AXIL_DATA_W-1:0] wr_data;
  logic [      StrbW-1:0] wr_strb;
  assign wr_addr = aw_pend ? aw_addr_q : s_axi_awaddr;
  assign wr_data = w_pend ? w_data_q : s_axi_wdata;
  assign wr_strb = w_pend ? w_strb_q : s_axi_wstrb;

  logic ctrl_wr, slope_wr;
  assign ctrl_wr  = wr_commit && wr_addr == RegCtrl;
  assign slope_wr = wr_commit && wr_addr == RegSlope;

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      aw_pend  <= 1'b0;
      w_pend   <= 1'b0;
      bvalid_q <= 1'b0;
    end else begin
      if (aw_fire) aw_addr_q <= s_axi_awaddr;
      if (w_fire) begin
        w_data_q <= s_axi_wdata;
        w_strb_q <= s_axi_wstrb;
      end

      if (wr_commit) begin
        aw_pend  <= 1'b0;
        w_pend   <= 1'b0;
        bvalid_q <= 1'b1;
      end else begin
        if (aw_fire) aw_pend <= 1'b1;
        if (w_fire) w_pend <= 1'b1;
      end

      if (bvalid_q && s_axi_bready) bvalid_q <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // The writable registers. Both are levels: there is no pulse in this map,
  // because a tile is not started by a register write.
  //
  // A slope written mid-tile takes effect on the next beat accepted. Nothing
  // here prevents that — the map says the driver sets the slope before the
  // tile, and an accelerator that silently ignored a write would be harder to
  // explain than one that applies it.
  // ---------------------------------------------------------------------------
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      ctrl_reg  <= CtrlReset;
      slope_reg <= SlopeW'(relu_pkg::SLOPE_RESET);
    end else begin
      if (ctrl_wr) begin
        for (int unsigned i = 0; i < StrbW; i++) begin
          if (wr_strb[i]) ctrl_reg[i*8+:8] <= wr_data[i*8+:8] & CtrlMask[i*8+:8];
        end
      end
      if (slope_wr && wr_strb[0]) slope_reg <= SlopeW'(wr_data & SlopeMask);
    end
  end

  // ---------------------------------------------------------------------------
  // The stream. One beat in, one beat out, one cycle apart: the output register
  // is the whole pipeline, and ready is withdrawn while it is occupied so a
  // beat that has been accepted is never dropped.
  // ---------------------------------------------------------------------------
  logic out_valid_q, out_last_q;
  logic signed [DATA_W-1:0] out_data_q;

  logic in_fire, out_fire;
  assign s_axis_tready = en_reg && (!out_valid_q || m_axis_tready);
  assign in_fire       = s_axis_tvalid && s_axis_tready;
  assign out_fire      = m_axis_tvalid && m_axis_tready;

  assign m_axis_tvalid = out_valid_q;
  assign m_axis_tdata  = out_data_q;
  assign m_axis_tlast  = out_last_q;

  logic signed [DATA_W-1:0] activated;
  relu_unit #(
      .DATA_W (DATA_W),
      .SLOPE_W(SlopeW)
  ) u_relu (
      .x    (signed'(s_axis_tdata)),
      .slope(slope_reg),
      .y    (activated)
  );

  logic tile_done;
  assign tile_done = out_fire && out_last_q;

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      out_valid_q <= 1'b0;
      out_last_q  <= 1'b0;
      out_data_q  <= '0;
    end else if (in_fire) begin
      out_valid_q <= 1'b1;
      out_last_q  <= s_axis_tlast;
      out_data_q  <= activated;
    end else if (out_fire) begin
      out_valid_q <= 1'b0;
      out_last_q  <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // Tile accounting. A tile begins with the first beat accepted and ends when
  // the beat carrying tlast leaves, so BUSY spans the pipeline rather than only
  // the input side — software that polled it otherwise would read COUNT one
  // beat early.
  // ---------------------------------------------------------------------------
  logic busy_q, done_q;
  logic [CountW-1:0] beats_q, count_q;

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      busy_q  <= 1'b0;
      done_q  <= 1'b0;
      beats_q <= '0;
      count_q <= '0;
    end else begin
      if (in_fire) begin
        beats_q <= beats_q + CountW'(1);
        if (!busy_q) begin
          busy_q <= 1'b1;
          done_q <= 1'b0;
        end
      end

      if (tile_done) begin
        busy_q  <= 1'b0;
        done_q  <= 1'b1;
        count_q <= in_fire ? beats_q + CountW'(1) : beats_q;
        beats_q <= '0;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // AXI4-Lite read channel
  // ---------------------------------------------------------------------------
  logic [AXIL_DATA_W-1:0] status_word;
  always_comb begin
    status_word = '0;
    status_word[StatusBusy] = busy_q;
    status_word[StatusDone] = done_q;
  end

  logic [AXIL_DATA_W-1:0] rd_mux;
  always_comb begin
    case (s_axi_araddr)
      RegId:     rd_mux = IdValue;
      RegCtrl:   rd_mux = ctrl_reg;
      RegStatus: rd_mux = status_word;
      RegSlope:  rd_mux = AXIL_DATA_W'(slope_reg);
      RegCount:  rd_mux = AXIL_DATA_W'(count_q);
      default:   rd_mux = '0;
    endcase
  end

  logic rvalid_q;
  logic [AXIL_DATA_W-1:0] rdata_q;
  assign s_axi_arready = !rvalid_q;
  assign s_axi_rvalid  = rvalid_q;
  assign s_axi_rdata   = rdata_q;
  assign s_axi_rresp   = 2'b00;

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      rvalid_q <= 1'b0;
      rdata_q  <= '0;
    end else if (s_axi_arvalid && s_axi_arready) begin
      rdata_q  <= rd_mux;
      rvalid_q <= 1'b1;
    end else if (rvalid_q && s_axi_rready) begin
      rvalid_q <= 1'b0;
    end
  end

  // Unused AXI4-Lite protection bits, tied off so -Wall stays clean.
  logic _unused;
  assign _unused = &{1'b0, s_axi_awprot, s_axi_arprot};

endmodule : relu_axi
