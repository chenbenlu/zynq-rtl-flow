// =============================================================================
// accel_contract_pkg
// The parts of the accelerator contract (docs/accelerator-contract.md) that a
// conforming accelerator can share: the control interface's widths and the
// layout of the ID register every accelerator answers a probe with.
//
// This package cannot carry the contract on its own. IP Integrator evaluates a
// module's header with no visibility of any package, so the widths below may be
// read internally but must be restated as literals in any module header that
// needs them, kept honest by an elaboration check. The contract itself lives in
// the document; this is only what RTL and testbenches can share of it.
// =============================================================================
package accel_contract_pkg;

  // AXI4-Lite control interface.
  parameter int unsigned AXIL_DATA_W = 32;
  parameter int unsigned AXIL_ADDR_W = 8;

  // The one offset the contract fixes. Everything above it belongs to the
  // accelerator's own register map.
  parameter int unsigned REG_ID_OFFSET = 'h00;

  // ID register: a 16-bit tag identifying the design, then major and minor
  // version. The tag is the accelerator's own; the layout is not.
  function automatic logic [31:0] id_value(input logic [15:0] tag, input logic [7:0] major,
                                           input logic [7:0] minor);
    return {tag, major, minor};
  endfunction

endpackage : accel_contract_pkg
