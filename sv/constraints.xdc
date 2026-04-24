# https://github.com/Digilent/Arty-S7-25-base/blob/master/src/constraints/Arty-S7-25-Master.xdc

# Clock
set_property -dict {PACKAGE_PIN R2 IOSTANDARD SSTL135} [get_ports fpga_clk]
create_clock -period 10.000 -name sys_clk_pin -waveform {0.000 5.000} -add [get_ports fpga_clk]

# Reset
set_property -dict {PACKAGE_PIN C18 IOSTANDARD LVCMOS33} [get_ports n_rst]

# PMOD JC - RF Front End
# JC pin 1 = WS
# JC pin 2 = SCK
# JC pin 3 = SD
set_property -dict {PACKAGE_PIN U15 IOSTANDARD LVCMOS33} [get_ports rf_ws]
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports rf_sck]
set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33} [get_ports rf_sd]

# PMOD JD - Bluetooth
# JD pin 1 = WS
# JD pin 2 = SCK
# JD pin 3 = SD
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVCMOS33} [get_ports bt_ws]
set_property -dict {PACKAGE_PIN U12 IOSTANDARD LVCMOS33} [get_ports bt_sck]
set_property -dict {PACKAGE_PIN V13 IOSTANDARD LVCMOS33} [get_ports bt_sd]

# random LED for debugging
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS33} [get_ports led1]
set_property -dict { PACKAGE_PIN F13   IOSTANDARD LVCMOS33 } [get_ports led2]; #IO_L17P_T2_A26_15 Sch=led[3]
set_property -dict { PACKAGE_PIN E13   IOSTANDARD LVCMOS33 } [get_ports led3]; #IO_L17N_T2_A25_15 Sch=led[4]
set_property -dict { PACKAGE_PIN H15   IOSTANDARD LVCMOS33 } [get_ports led4]; #IO_L18P_T2_A24_15 Sch=led[5]

# Configuration
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property INTERNAL_VREF 0.675 [get_iobanks 34]

create_debug_core u_ila_0 ila
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_0]
set_property ALL_PROBE_SAME_MU_CNT 1 [get_debug_cores u_ila_0]
set_property C_ADV_TRIGGER false [get_debug_cores u_ila_0]
set_property C_DATA_DEPTH 1024 [get_debug_cores u_ila_0]
set_property C_EN_STRG_QUAL false [get_debug_cores u_ila_0]
set_property C_INPUT_PIPE_STAGES 0 [get_debug_cores u_ila_0]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_0]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_0]
set_property port_width 1 [get_debug_ports u_ila_0/clk]
connect_debug_port u_ila_0/clk [get_nets [list fpga_clk_IBUF_BUFG]]
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe0]
set_property port_width 8 [get_debug_ports u_ila_0/probe0]
connect_debug_port u_ila_0/probe0 [get_nets [list {dbg_sample_i[0]} {dbg_sample_i[1]} {dbg_sample_i[2]} {dbg_sample_i[3]} {dbg_sample_i[4]} {dbg_sample_i[5]} {dbg_sample_i[6]} {dbg_sample_i[7]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe1]
set_property port_width 8 [get_debug_ports u_ila_0/probe1]
connect_debug_port u_ila_0/probe1 [get_nets [list {dbg_sample_q[0]} {dbg_sample_q[1]} {dbg_sample_q[2]} {dbg_sample_q[3]} {dbg_sample_q[4]} {dbg_sample_q[5]} {dbg_sample_q[6]} {dbg_sample_q[7]}]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe2]
set_property port_width 1 [get_debug_ports u_ila_0/probe2]
connect_debug_port u_ila_0/probe2 [get_nets [list dbg_rf_sck]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe3]
set_property port_width 1 [get_debug_ports u_ila_0/probe3]
connect_debug_port u_ila_0/probe3 [get_nets [list dbg_rf_sd]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe4]
set_property port_width 1 [get_debug_ports u_ila_0/probe4]
connect_debug_port u_ila_0/probe4 [get_nets [list dbg_rf_ws]]
create_debug_port u_ila_0 probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe5]
set_property port_width 1 [get_debug_ports u_ila_0/probe5]
connect_debug_port u_ila_0/probe5 [get_nets [list dbg_sample_valid]]
set_property C_CLK_INPUT_FREQ_HZ 300000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets fpga_clk_IBUF_BUFG]
