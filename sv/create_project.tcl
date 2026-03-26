# Set up a new project
create_project FPGA-BASED-SDR ./ -part xc7a25tcsg325-2 -force

set_property SIMULATOR_LANGUAGE Verilog [current_project]

# ADD IP BLOCKS HERE

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