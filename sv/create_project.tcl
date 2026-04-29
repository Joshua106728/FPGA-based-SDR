# Set up a new project
create_project FPGA_SDR ./ -part xc7s25csga324-1 -force

set_property SIMULATOR_LANGUAGE Verilog [current_project]

##################################################################
# CREATE IP low_pass_filter
##################################################################

set low_pass_filter [create_ip -name fir_compiler -vendor xilinx.com -library ip -version 7.2 -module_name low_pass_filter]

# User Parameters
set_property -dict [list \
  CONFIG.Clock_Frequency {100.0} \
  CONFIG.CoefficientSource {COE_File} \
  CONFIG.Coefficient_File {c:/Users/jhwjh/FPGA-based-SDR/sv/lpf_coeffs.coe} \
  CONFIG.Coefficient_Fractional_Bits {0} \
  CONFIG.Coefficient_Sets {1} \
  CONFIG.Coefficient_Sign {Signed} \
  CONFIG.Coefficient_Structure {Symmetric} \
  CONFIG.Coefficient_Width {18} \
  CONFIG.Data_Fractional_Bits {10} \
  CONFIG.Data_Width {18} \
  CONFIG.Filter_Architecture {Systolic_Multiply_Accumulate} \
  CONFIG.Has_ARESETn {true} \
  CONFIG.Output_Rounding_Mode {Truncate_LSBs} \
  CONFIG.Output_Width {18} \
  CONFIG.Quantization {Quantize_Only} \
  CONFIG.Sample_Frequency {0.25} \
] [get_ips low_pass_filter]

# Runtime Parameters
set_property -dict { 
  GENERATE_SYNTH_CHECKPOINT {1}
} $low_pass_filter

generate_target all [get_ips low_pass_filter]
##################################################################

##################################################################
# INCLUDE DIRECTORY
##################################################################
set include_path [file normalize "./include"]
set_property include_dirs [list $include_path] [get_filesets sources_1]
set_property include_dirs [list $include_path] [get_filesets sim_1]

foreach file [glob -nocomplain ${include_path}/*.vh ${include_path}/*.sv] {
    add_files -fileset sources_1 $file
    set_property file_type "Verilog Header" [get_files [file tail $file]]
}

##################################################################
# RTL SOURCES
##################################################################
foreach file [glob -nocomplain ./src/*.sv ./src/*.v] {
    add_files -fileset sources_1 $file
    if {[string match "*.sv" $file]} {
        set_property file_type "SystemVerilog" [get_files [file tail $file]]
    }
}

##################################################################
# TESTBENCHES
##################################################################
foreach file [glob -nocomplain ./tb/*.sv ./tb/*.v] {
    add_files -fileset sim_1 $file
    if {[string match "*.sv" $file]} {
        set_property file_type "SystemVerilog" [get_files [file tail $file] -of_objects [get_filesets sim_1]]
    }
}

##################################################################
# WAVE CONFIGS
##################################################################
foreach file [glob -nocomplain ./waves/*.wcfg] {
    add_files -fileset sim_1 $file
}

##################################################################
# CONSTRAINTS
##################################################################
if {[file exists constraints.xdc]} {
    add_files -fileset constrs_1 constraints.xdc
}

##################################################################
# FINALIZE
##################################################################
set_property top top [get_filesets sources_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "Project created successfully."