// =============================================================================
// relu_pkg
// Widths belonging to the Leaky ReLU accelerator alone — the second example,
// not the environment. What every conforming accelerator shares lives in
// accel_contract_pkg.
// =============================================================================
package relu_pkg;

  // Activation width, signed, in and out.
  parameter int unsigned DATA_W = 8;

  // Negative slope, unsigned Q0.8.
  parameter int unsigned SLOPE_W = 8;

  // Default slope: 25/256 ~ 0.098, the usual leaky-ReLU coefficient rounded to
  // the fraction this width can hold.
  parameter int unsigned SLOPE_RESET = 25;

  // Width of the beat counter a completed tile is reported over.
  parameter int unsigned COUNT_W = 16;

endpackage : relu_pkg
