// =============================================================================
// sparse_cnn_pkg
// Shared parameters and types for the Sparse CNN accelerator skeleton.
// Centralising widths here keeps the RTL and (future) PE array consistent.
// =============================================================================
package sparse_cnn_pkg;

  // Operand bit-width for signed weights and activations.
  parameter int unsigned DATA_W = 8;

  // Accumulator bit-width. Sized generously so a tile of full-magnitude
  // products cannot overflow before a read-out / clear.
  parameter int unsigned ACC_W = 32;

  // Width of the saturating-free zero-skip counter (verification observability).
  parameter int unsigned SKIP_W = 16;

endpackage : sparse_cnn_pkg
