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
] $ps

# --- Reset -------------------------------------------------------------------
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_pl]

# --- DMA: feeds the accelerator's stream -------------------------------------
set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma dma]
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_s2mm {0} \
    CONFIG.c_m_axi_mm2s_data_width {32} \
    CONFIG.c_m_axis_mm2s_tdata_width {16} \
    CONFIG.c_mm2s_burst_size {16} \
] $dma

# --- The accelerator ---------------------------------------------------------
set accel [create_bd_cell -type module -reference sparse_cnn_axi accel]

# --- Interconnect ------------------------------------------------------------
set ctrl_ic [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect ctrl_ic]
set_property -dict {CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}} $ctrl_ic

set mem_ic [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect mem_ic]
set_property -dict {CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}} $mem_ic

connect_bd_intf_net [get_bd_intf_pins ps/M_AXI_HPM0_FPD] [get_bd_intf_pins ctrl_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ctrl_ic/M00_AXI]   [get_bd_intf_pins dma/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins ctrl_ic/M01_AXI]   [get_bd_intf_pins accel/s_axi]

connect_bd_intf_net [get_bd_intf_pins dma/M_AXI_MM2S]    [get_bd_intf_pins mem_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins mem_ic/M00_AXI]    [get_bd_intf_pins ps/S_AXI_HP0_FPD]

connect_bd_intf_net [get_bd_intf_pins dma/M_AXIS_MM2S]   [get_bd_intf_pins accel/s_axis]

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

connect_bd_net [get_bd_pins ps/pl_resetn0] [get_bd_pins rst_pl/ext_reset_in]

connect_bd_net [get_bd_pins rst_pl/peripheral_aresetn] \
    [get_bd_pins ctrl_ic/aresetn] \
    [get_bd_pins mem_ic/aresetn] \
    [get_bd_pins dma/axi_resetn] \
    [get_bd_pins accel/aresetn]

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
