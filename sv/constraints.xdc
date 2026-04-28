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
set_false_path -from [get_ports {rf_ws rf_sck rf_sd}]

# JD pin 1 = WS
# JD pin 2 = SCK
# JD pin 3 = SD
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVCMOS33} [get_ports bt_ws]
set_property -dict {PACKAGE_PIN U12 IOSTANDARD LVCMOS33} [get_ports bt_sck]
set_property -dict {PACKAGE_PIN V13 IOSTANDARD LVCMOS33} [get_ports bt_sd]

# random LED for debugging
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS33} [get_ports led1]
set_property -dict {PACKAGE_PIN F13 IOSTANDARD LVCMOS33} [get_ports led2]
set_property -dict {PACKAGE_PIN E13 IOSTANDARD LVCMOS33} [get_ports led3]
set_property -dict {PACKAGE_PIN H15 IOSTANDARD LVCMOS33} [get_ports led4]

# Configuration
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]

# ILA Garbage
