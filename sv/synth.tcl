open_project FPGA_SDR.xpr

# Create reports directory if it doesn't exist
file mkdir reports

launch_runs synth_1 -jobs 4
wait_on_run synth_1

# Check if synthesis succeeded before trying to open the run
if {[get_property STATUS [get_runs synth_1]] != "synth_design Complete!"} {
    puts "ERROR: Synthesis failed with status: [get_property STATUS [get_runs synth_1]]"
    exit 1
}

open_run synth_1 -name synth_1

report_utilization -file reports/utilization_synth.rpt
report_timing_summary -file reports/timing_synth.rpt

puts "Synthesis complete successfully."