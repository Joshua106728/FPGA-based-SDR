# Set up a new project
create_project FPGA_SDR ./ -part xc7a25tcsg325-2 -force

set_property SIMULATOR_LANGUAGE Verilog [current_project]

# ADD IP BLOCKS HERE
##################################################################
# CREATE IP fifo
##################################################################

set fifo [create_ip -name fifo_generator -vendor xilinx.com -library ip -version 13.2 -module_name fifo]

# User Parameters
set_property -dict [list \
  CONFIG.Fifo_Implementation {Independent_Clocks_Block_RAM} \
  CONFIG.Input_Depth {16} \
  CONFIG.Valid_Flag {true} \
] [get_ips fifo]

# Runtime Parameters
set_property -dict { 
  GENERATE_SYNTH_CHECKPOINT {1}
} $fifo

generate_target all [get_ips fifo]
##################################################################

add_files constraints.xdc
set_property FILE_TYPE XDC [get_files constraints.xdc]
set_property top AFC [current_fileset] 

set include_path "./include"
foreach file [glob -directory $include_path *] {
     add_files $file    
}
set src_path "./src"
foreach file [glob -directory $src_path *] {
     add_files $file    
}
set tb_path "./tb"
foreach file [glob -directory $tb_path *] {
     add_files $file    
}
set wav_path "./waves"
foreach file [glob -directory $wav_path *] {
     add_files $file    
}