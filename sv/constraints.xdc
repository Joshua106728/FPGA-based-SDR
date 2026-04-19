# https://github.com/Digilent/Arty-S7-25-base/blob/master/src/constraints/Arty-S7-25-Master.xdc

set_property -dict {PACKAGE_PIN R2 IOSTANDARD SSTL135} [get_ports { fpga_clk }]
create_clock -period 10.000 -name sys_clk_pin -waveform {0.000 5.000} -add [get_ports { fpga_clk }]

set_property -dict {PACKAGE_PIN C18 IOSTANDARD LVCMOS33} [get_ports { n_rst }]