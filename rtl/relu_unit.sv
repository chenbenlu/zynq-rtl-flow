// =============================================================================
// relu_unit
// Leaky ReLU activation: y = x for x >= 0, y = x * slope for x < 0.
//
// slope is unsigned Q0.8 — the fraction slope/256 — so the negative branch is a
// multiply and an arithmetic shift, and the shift truncates towards minus
// infinity. That truncation is the definition, not an approximation of one: the
// golden model does the same and the two are compared exactly.
//
// Combinational. The pipeline register and the backpressure that goes with it
// belong to the wrapper, which is the only part that knows when a beat may be
// accepted.
// =============================================================================
module relu_unit #(
    parameter int unsigned DATA_W  = 8,
    parameter int unsigned SLOPE_W = 8
) (
    input  logic signed [ DATA_W-1:0] x,
    input  logic        [SLOPE_W-1:0] slope,
    output logic signed [ DATA_W-1:0] y
);

  // The product needs the operand's width plus the slope's, and one bit more
  // because an unsigned slope has to be widened signed to multiply.
  localparam int unsigned ProdW = DATA_W + SLOPE_W + 1;

  logic signed [ProdW-1:0] scaled;
  assign scaled = signed'({{(SLOPE_W + 1) {1'b0}}, slope}) * ProdW'(x);

  assign y = (x >= 0) ? x : DATA_W'(scaled >>> SLOPE_W);

endmodule : relu_unit
