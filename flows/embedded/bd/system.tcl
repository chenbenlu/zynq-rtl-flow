# =============================================================================
# The system block design. See bd/README.md for the shape and the reasoning;
# sourced by flows/embedded/impl.tcl, which supplies the project and the RTL.
# =============================================================================

set bd_name    system
set board_file $::env(BOARD_FILE)
set pl_clk_mhz $::env(PL_CLK_MHZ)

create_bd_design $bd_name

# --- Zynq PS -----------------------------------------------------------------
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e ps]
if {$board_file ne ""} {
  apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
      -config {apply_board_preset "1"} $ps
}

# HPM0 masters the control path, HP0 is the DMA's window into DDR. 32-bit is
# ample for both: one control transaction per tile, one 16-bit pair per beat.
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__USE__M_AXI_GP2 {0} \
    CONFIG.PSU__USE__S_AXI_GP2 {1} \
    CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
    CONFIG.PSU__SAXIGP2__DATA_WIDTH {32} \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $pl_clk_mhz \
    CONFIG.PSU__USE__IRQ0 {1} \
] $ps

# --- Reset -------------------------------------------------------------------
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_pl]

# --- The accelerator ---------------------------------------------------------
# Whatever module scripts/rtl_sources.sh names as the top, so the design is the
# environment's and not one accelerator's. It has to conform to
# docs/accelerator-contract.md; the connections below are exactly that contract.
set accel [create_bd_cell -type module -reference $::env(RTL_TOP) accel]

# The contract makes the stream master optional: an accelerator that reduces a
# tile reports through registers, one that transforms it beat by beat has
# nowhere else to put its output. Everything S2MM below hangs off this.
set accel_m_axis [get_bd_intf_pins -quiet accel/m_axis]
set has_m_axis [expr {$accel_m_axis ne ""}]

# The DMA's stream widths are the accelerator's, read off the ports rather than
# restated here — a restatement would be a second place to edit, and the whole
# point of the contract is that a new accelerator does not need one.
proc axis_tdata_width {pin} {
  set bytes [get_property -quiet CONFIG.TDATA_NUM_BYTES [get_bd_intf_pins $pin]]
  if {$bytes eq "" || $bytes == 0} {
    error "cannot read the width of $pin — the DMA's stream would not match the accelerator"
  }
  return [expr {8 * $bytes}]
}

# --- DMA: feeds the accelerator's stream, and drains it if it has an output ---
set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma dma]
set dma_cfg [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_m_axi_mm2s_data_width {32} \
    CONFIG.c_m_axis_mm2s_tdata_width [axis_tdata_width accel/s_axis] \
    CONFIG.c_mm2s_burst_size {16} \
]
if {$has_m_axis} {
  lappend dma_cfg \
      CONFIG.c_include_s2mm {1} \
      CONFIG.c_m_axi_s2mm_data_width {32} \
      CONFIG.c_s_axis_s2mm_tdata_width [axis_tdata_width accel/m_axis] \
      CONFIG.c_s2mm_burst_size {16}
} else {
  lappend dma_cfg CONFIG.c_include_s2mm {0}
}
set_property -dict $dma_cfg $dma

# --- Interconnect ------------------------------------------------------------
set ctrl_ic [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect ctrl_ic]
set_property -dict {CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}} $ctrl_ic

set mem_ic [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect mem_ic]
set_property -dict [list CONFIG.NUM_SI [expr {$has_m_axis ? 2 : 1}] CONFIG.NUM_MI {1}] $mem_ic

connect_bd_intf_net [get_bd_intf_pins ps/M_AXI_HPM0_FPD] [get_bd_intf_pins ctrl_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ctrl_ic/M00_AXI]   [get_bd_intf_pins dma/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins ctrl_ic/M01_AXI]   [get_bd_intf_pins accel/s_axi]

connect_bd_intf_net [get_bd_intf_pins dma/M_AXI_MM2S]    [get_bd_intf_pins mem_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins mem_ic/M00_AXI]    [get_bd_intf_pins ps/S_AXI_HP0_FPD]

connect_bd_intf_net [get_bd_intf_pins dma/M_AXIS_MM2S]   [get_bd_intf_pins accel/s_axis]

if {$has_m_axis} {
  connect_bd_intf_net [get_bd_intf_pins accel/m_axis]     [get_bd_intf_pins dma/S_AXIS_S2MM]
  connect_bd_intf_net [get_bd_intf_pins dma/M_AXI_S2MM]   [get_bd_intf_pins mem_ic/S01_AXI]
}

# --- Clock and reset ---------------------------------------------------------
connect_bd_net [get_bd_pins ps/pl_clk0] \
    [get_bd_pins ps/maxihpm0_fpd_aclk] \
    [get_bd_pins ps/saxihp0_fpd_aclk] \
    [get_bd_pins rst_pl/slowest_sync_clk] \
    [get_bd_pins ctrl_ic/aclk] \
    [get_bd_pins mem_ic/aclk] \
    [get_bd_pins dma/s_axi_lite_aclk] \
    [get_bd_pins dma/m_axi_mm2s_aclk] \
    [get_bd_pins accel/aclk]

if {$has_m_axis} {
  connect_bd_net [get_bd_pins ps/pl_clk0] [get_bd_pins dma/m_axi_s2mm_aclk]
}

connect_bd_net [get_bd_pins ps/pl_resetn0] [get_bd_pins rst_pl/ext_reset_in]

connect_bd_net [get_bd_pins rst_pl/peripheral_aresetn] \
    [get_bd_pins ctrl_ic/aresetn] \
    [get_bd_pins mem_ic/aresetn] \
    [get_bd_pins dma/axi_resetn] \
    [get_bd_pins accel/aresetn]

# --- Interrupt ---------------------------------------------------------------
# Without this the DMA's completion interrupt reaches no GIC input, the device
# tree the handoff generates carries no `interrupts` property, and the Linux
# driver refuses to probe ("failed to get irq", -EINVAL) — the design looks
# complete and place & route succeeds either way.
#
# pl_ps_irq0 is a vector sized by PSU__NUM_F2P0__INTR__INPUTS, which IP
# Integrator derives from the connections made to the port and refuses to have
# set (`Cannot set the parameter ... It is read-only`, a CRITICAL WARNING that
# also keeps the synthesis run out of the cache). One source therefore gives a
# one-bit port and connects directly; a second means driving the port from an
# xlconcat and letting the width follow.
#
# An accelerator with a stream master gives the second: the DMA raises one
# interrupt per direction, and the one saying the results reached DDR is the one
# software waits on.
if {$has_m_axis} {
  set irq_concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat irq_concat]
  set_property CONFIG.NUM_PORTS {2} $irq_concat
  connect_bd_net [get_bd_pins dma/mm2s_introut] [get_bd_pins irq_concat/In0]
  connect_bd_net [get_bd_pins dma/s2mm_introut] [get_bd_pins irq_concat/In1]
  connect_bd_net [get_bd_pins irq_concat/dout]  [get_bd_pins ps/pl_ps_irq0]
} else {
  connect_bd_net [get_bd_pins dma/mm2s_introut] [get_bd_pins ps/pl_ps_irq0]
}

assign_bd_address
validate_bd_design
save_bd_design

# The address map is what the PS-side driver needs; record it next to the
# reports rather than making someone open the GUI to find it.
if {[info exists ::env(OUT_DIR)]} {
  set fh [open $::env(OUT_DIR)/address_map.txt w]
  foreach seg [get_bd_addr_segs] {
    set offset [get_property -quiet OFFSET $seg]
    set range  [get_property -quiet RANGE $seg]
    if {$offset ne ""} {
      puts $fh [format "%-52s offset %-12s range %s" $seg $offset $range]
    }
  }
  close $fh
}
