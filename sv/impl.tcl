open_project FPGA_SDR.xpr

file mkdir reports

launch_runs impl_1 -jobs 4
wait_on_run impl_1

# Check PROGRESS instead of STATUS — more reliable
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Implementation failed: [get_property STATUS [get_runs impl_1]]"
    exit 1
}

open_run impl_1 -name impl_1

report_timing_summary -file reports/timing_impl.rpt
report_utilization    -file reports/utilization_impl.rpt
report_io             -file reports/io_impl.rpt

puts "Implementation complete: [get_property STATUS [get_runs impl_1]]"