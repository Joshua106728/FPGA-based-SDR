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
# CREATE IP div
##################################################################

set div [create_ip -name div_gen -vendor xilinx.com -library ip -version 5.1 -module_name div]

# User Parameters
set_property -dict [list \
  CONFIG.ARESETN {true} \
  CONFIG.algorithm_type {High_Radix} \
  CONFIG.dividend_and_quotient_width {32} \
  CONFIG.divisor_width {24} \
  CONFIG.fractional_width {0} \
  CONFIG.latency {26} \
  CONFIG.remainder_type {Fractional} \
] [get_ips div]

# Runtime Parameters
set_property -dict { 
  GENERATE_SYNTH_CHECKPOINT {1}
} $div

generate_target all [get_ips div]
##################################################################

##################################################################
# CREATE IP ila_debug
##################################################################

set ila_debug [create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_debug]

set_property -dict [list \
  CONFIG.C_NUM_OF_PROBES  {12}   \
  CONFIG.C_DATA_DEPTH     {1024} \
  CONFIG.C_TRIGIN_EN      {false} \
  CONFIG.C_TRIGOUT_EN     {false} \
  CONFIG.ALL_PROBE_SAME_MU      {true} \
  CONFIG.ALL_PROBE_SAME_MU_CNT  {1}    \
  CONFIG.C_PROBE0_WIDTH   {3}    \
  CONFIG.C_PROBE1_WIDTH   {8}    \
  CONFIG.C_PROBE2_WIDTH   {8}    \
  CONFIG.C_PROBE3_WIDTH   {1}    \
  CONFIG.C_PROBE4_WIDTH   {18}   \
  CONFIG.C_PROBE5_WIDTH   {18}   \
  CONFIG.C_PROBE6_WIDTH   {1}    \
  CONFIG.C_PROBE7_WIDTH   {18}   \
  CONFIG.C_PROBE8_WIDTH   {1}    \
  CONFIG.C_PROBE9_WIDTH   {18}   \
  CONFIG.C_PROBE10_WIDTH  {1}    \
  CONFIG.C_PROBE11_WIDTH  {3}    \
] [get_ips ila_debug]

set_property -dict {GENERATE_SYNTH_CHECKPOINT {1}} $ila_debug
generate_target all [get_ips ila_debug]
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