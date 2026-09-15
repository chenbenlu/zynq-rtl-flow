// =============================================================================
// sparse_cnn_axi
// AXI-wrapped accelerator top level: makes sparse_mac_pe addressable by the
// Zynq PS. The PE itself is instantiated unmodified.
//
// Two interfaces, split by data rate:
//   s_axis  AXI4-Stream slave — one packed (act, weight) operand pair per beat,
//           backpressured. tlast marks the end of a tile.
//   s_axi   AXI4-Lite slave  — control, status and results; one transaction per
//           tile rather than per beat.
//
// Register map (byte offsets, 32-bit words) — see docs/register-map.md:
//   0x00  ID      RO  {"SP", major, minor}
//   0x04  CTRL    RW  [0] START (W1P) [1] CLEAR (W1P) [2] EN (level, reset 1)
//   0x08  STATUS  RO  [0] BUSY [1] DONE
//   0x0C  ACC     RO  accumulator of the last completed tile
//   0x10  SKIP    RO  zero-skip count of the last completed tile
//
// Results are latched at the end of a tile, so a read issued before completion
// returns the last completed tile rather than a partial accumulation.
//
// Single clock domain: everything runs on aclk, the PL clock sourced by the PS.
// =============================================================================
module sparse_cnn_axi #(
    // The control interface's own widths. The operand widths are localparams
    // below, not parameters: IP Integrator evaluates a parameter's default
    // without visibility of the package, so a package-scoped default stops the
    // module being inferred into a block design at all.
    parameter int unsigned AXIL_DATA_W = 32,
    parameter int unsigned AXIL_ADDR_W = 8
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi:s_axis, ASSOCIATED_RESET aresetn" *)
    input logic aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input logic aresetn,

    // --- AXI4-Lite slave: control / status / results ---
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

    // --- AXI4-Stream slave: one operand pair per beat ---
    input  logic [2*sparse_cnn_pkg::DATA_W-1:0] s_axis_tdata,
    input  logic                                s_axis_tvalid,
    output logic                                s_axis_tready,
    input  logic                                s_axis_tlast
);

  // Operand widths, from the shared package. Nothing overrides them.
  localparam int unsigned DataW = sparse_cnn_pkg::DATA_W;
  localparam int unsigned AccW = sparse_cnn_pkg::ACC_W;
  localparam int unsigned SkipW = sparse_cnn_pkg::SKIP_W;

  localparam int unsigned StrbW = AXIL_DATA_W / 8;

  // Register offsets. Decoding the full byte address (rather than a word index)
  // keeps unaligned accesses landing on the default arm instead of aliasing.
  localparam logic [AXIL_ADDR_W-1:0] RegId = 'h00;
  localparam logic [AXIL_ADDR_W-1:0] RegCtrl = 'h04;
  localparam logic [AXIL_ADDR_W-1:0] RegStatus = 'h08;
  localparam logic [AXIL_ADDR_W-1:0] RegAcc = 'h0C;
  localparam logic [AXIL_ADDR_W-1:0] RegSkip = 'h10;

  localparam int unsigned CtrlStart = 0;
  localparam int unsigned CtrlClear = 1;
  localparam int unsigned CtrlEn = 2;
  localparam int unsigned StatusBusy = 0;
  localparam int unsigned StatusDone = 1;

  // Software reads this before writing anything to confirm what it is talking
  // to: "SP" (sparse accelerator) then major, minor.
  localparam logic [31:0] IdValue = {16'h5350, 8'd1, 8'd0};

  localparam logic [AXIL_DATA_W-1:0] CtrlReset = AXIL_DATA_W'(1) << CtrlEn;

  // Everything outside the three defined bits reads 0 and swallows writes, so
  // the register carries no driver-visible state the map does not describe.
  localparam logic [AXIL_DATA_W-1:0] CtrlMask =
      (AXIL_DATA_W'(1) << CtrlStart) | (AXIL_DATA_W'(1) << CtrlClear) |
      (AXIL_DATA_W'(1) << CtrlEn);

  typedef enum logic [1:0] {
    S_IDLE,   // no tile in flight; results hold the last completed tile
    S_CLEAR,  // one cycle clearing the PE before operands arrive
    S_RUN,    // consuming stream beats
    S_LATCH   // the PE has absorbed the last beat; sample it into the results
  } tile_state_e;

  tile_state_e                   state;

  logic        [AXIL_DATA_W-1:0] ctrl_reg;
  logic                          done_q;
  logic signed [       AccW-1:0] acc_q;
  logic        [      SkipW-1:0] skip_q;

  logic start_pulse, clear_pulse, en_reg;
  assign start_pulse = ctrl_reg[CtrlStart];
  assign clear_pulse = ctrl_reg[CtrlClear];
  assign en_reg      = ctrl_reg[CtrlEn];

  // ---------------------------------------------------------------------------
  // AXI4-Lite write channel
  //
  // Address and data are captured independently and applied together. Neither
  // ready is derived from its own valid, so no combinational loop can form.
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

  logic ctrl_wr;
  assign ctrl_wr = wr_commit && wr_addr == RegCtrl;

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
  // Control register. START and CLEAR are write-1-to-pulse and read back 0;
  // EN is a level the driver read-modify-writes.
  // ---------------------------------------------------------------------------
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      ctrl_reg <= CtrlReset;
    end else begin
      ctrl_reg[CtrlStart] <= 1'b0;
      ctrl_reg[CtrlClear] <= 1'b0;
      if (ctrl_wr) begin
        for (int unsigned i = 0; i < StrbW; i++) begin
          if (wr_strb[i]) ctrl_reg[i*8+:8] <= wr_data[i*8+:8] & CtrlMask[i*8+:8];
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // AXI4-Lite read channel
  // ---------------------------------------------------------------------------
  // A START is visible to software from the cycle its write commits: an AR
  // sampled on that very edge, and then the cycles the pulse takes to reach the
  // tile FSM. Reporting `state` and `done_q` raw leaves STATUS showing BUSY=0,
  // DONE=1 across that gap — bit-for-bit a completed tile — so a poll loop that
  // does not wait for the write response falls through it into the previous
  // tile's ACC and SKIP. Breaking the tie in the write's favour is what lets
  // the register map promise a poll loop that needs no fence.
  logic start_taken;
  assign start_taken = start_pulse || (ctrl_wr && wr_strb[CtrlStart/8] && wr_data[CtrlStart]);

  logic [AXIL_DATA_W-1:0] status_word;
  always_comb begin
    status_word = '0;
    status_word[StatusBusy] = (state != S_IDLE) || start_taken;
    status_word[StatusDone] = done_q && !start_taken;
  end

  logic [AXIL_DATA_W-1:0] rd_mux;
  always_comb begin
    case (s_axi_araddr)
      RegId:     rd_mux = IdValue;
      RegCtrl:   rd_mux = ctrl_reg;
      RegStatus: rd_mux = status_word;
      RegAcc:    rd_mux = AXIL_DATA_W'(acc_q);
      RegSkip:   rd_mux = AXIL_DATA_W'(skip_q);
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

  // ---------------------------------------------------------------------------
  // Tile sequencing and the stream
  // ---------------------------------------------------------------------------
  logic beat;
  assign beat = s_axis_tvalid && s_axis_tready;

  // Ready only when the PE will actually consume the beat: a beat that is
  // accepted is never dropped. The explicit-clear pulse withdraws ready for its
  // one cycle so it cannot race an in-flight beat.
  assign s_axis_tready = (state == S_RUN) && en_reg && !clear_pulse;

  logic pe_clear, pe_en;
  assign pe_clear = (state == S_CLEAR) || clear_pulse;

  // The PE's enable is its freeze control, which is exactly what a stalled
  // stream needs: it advances only on a beat or a clear, and holds otherwise.
  assign pe_en = beat || pe_clear;

  logic signed [AccW-1:0] pe_acc;
  logic [SkipW-1:0] pe_skip;
  /* verilator lint_off UNUSEDSIGNAL */
  // The PE marks the cycle it consumed a pair; the wrapper already tracks that
  // itself as `beat`. Connected rather than left dangling so the pin is explicit.
  logic pe_valid_out;
  /* verilator lint_on UNUSEDSIGNAL */

  sparse_mac_pe #(
      .DATA_W(DataW),
      .ACC_W (AccW),
      .SKIP_W(SkipW)
  ) u_pe (
      .clk       (aclk),
      .rst_n     (aresetn),
      .en        (pe_en),
      .clear_acc (pe_clear),
      .valid_in  (beat),
      .weight    (s_axis_tdata[DataW-1:0]),
      .act       (s_axis_tdata[2*DataW-1:DataW]),
      .acc       (pe_acc),
      .valid_out (pe_valid_out),
      .skip_count(pe_skip)
  );

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      state  <= S_IDLE;
      done_q <= 1'b0;
      acc_q  <= '0;
      skip_q <= '0;
    end else begin
      case (state)
        S_IDLE: begin
          if (start_pulse) begin
            state  <= S_CLEAR;
            done_q <= 1'b0;
          end
        end
        S_CLEAR: state <= S_RUN;
        S_RUN:   if (beat && s_axis_tlast) state <= S_LATCH;
        S_LATCH: begin
          // The PE absorbed the last beat on the edge that entered this state,
          // so its outputs are the tile's final values now.
          acc_q  <= pe_acc;
          skip_q <= pe_skip;
          done_q <= 1'b1;
          state  <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase

      // An explicit clear wins over a latch in the same cycle: software asked
      // for the tile state to be gone.
      if (clear_pulse) begin
        acc_q  <= '0;
        skip_q <= '0;
      end
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  // Protection attributes are accepted for AXI4-Lite compliance; this slave
  // makes no access-permission distinction.
  logic [5:0] unused_prot;
  assign unused_prot = {s_axi_awprot, s_axi_arprot};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule : sparse_cnn_axi
