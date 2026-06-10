// =============================================================================
// sparse_mac_pe
// Sparse multiply-accumulate processing element.
//
// Streams (weight, activation) pairs and accumulates their signed products.
// The key sparse-CNN behaviour is ZERO-SKIP: when either operand is zero the
// multiply-add is suppressed (no contribution, no toggling of the product
// path) and a skip counter is advanced instead. This models the work a real
// sparse accelerator avoids, and the counter gives the testbench a direct
// observable to confirm the skipping is exact.
//
// Control:
//   en        - global enable; when low the PE freezes (holds all state)
//   clear_acc - synchronous clear of acc + skip_count (start of a new tile)
//   valid_in  - the operand pair on this cycle is valid
//
// Reset is synchronous, active-low.
// =============================================================================
module sparse_mac_pe #(
    parameter int unsigned DATA_W = sparse_cnn_pkg::DATA_W,
    parameter int unsigned ACC_W  = sparse_cnn_pkg::ACC_W,
    parameter int unsigned SKIP_W = sparse_cnn_pkg::SKIP_W
) (
    input  logic                     clk,
    input  logic                     rst_n,
    input  logic                     en,
    input  logic                     clear_acc,
    input  logic                     valid_in,
    input  logic signed [DATA_W-1:0] weight,
    input  logic signed [DATA_W-1:0] act,
    output logic signed [ ACC_W-1:0] acc,
    output logic                     valid_out,
    output logic        [SKIP_W-1:0] skip_count
);

  // A valid pair is skipped when either operand is zero.
  logic is_zero;
  logic do_mac;
  assign is_zero = (weight == '0) || (act == '0);
  assign do_mac  = valid_in && !is_zero;

  // Signed product, sign-extended into the accumulator width.
  logic signed [ACC_W-1:0] product;
  assign product = ACC_W'(weight * act);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      acc        <= '0;
      skip_count <= '0;
      valid_out  <= 1'b0;
    end else if (en) begin
      if (clear_acc) begin
        // Highest priority: reset the tile state.
        acc        <= '0;
        skip_count <= '0;
      end else begin
        if (do_mac) begin
          acc <= acc + product;
        end
        if (valid_in && is_zero) begin
          skip_count <= skip_count + SKIP_W'(1);
        end
      end

      // valid_out marks a cycle that consumed a valid pair (clear has priority).
      valid_out <= valid_in && !clear_acc;
    end else begin
      // Frozen: hold acc/skip_count, deassert valid_out.
      valid_out <= 1'b0;
    end
  end

endmodule : sparse_mac_pe
