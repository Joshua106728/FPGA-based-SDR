# WINDOWS
setup:
	vivado -mode batch -source create_project.tcl

clean:
	powershell -Command "Remove-Item -Force -ErrorAction SilentlyContinue *.log,*.jou,*.wdb,*.str, *.pb, dfx_runtime.txt, *.xpr"
	powershell -Command "Remove-Item -Recurse -Force -ErrorAction SilentlyContinue .Xil, FPGA_SDR.cache, FPGA_SDR.gen, FPGA_SDR.hw, FPGA_SDR.ip_user_files, FPGA_SDR.srcs, FPGA_SDR.runs, FPGA_SDR.sim, reports, xsim.dir"

%.sim:
	for %%f in (src\*.sv) do xvlog -sv %%f
	xvlog -sv ./tb/$*_tb.sv

	xvhdl ./FPGA_SDR.gen/sources_1/ip/sim/low_pass_filter.vhd

	xelab -debug typical $*_tb -s $*_sim
	xsim $*_sim -gui -view ./waves/$*_sim.wcfg

synth:
	vivado -mode batch -source synth.tcl

impl:
	vivado -mode batch -source impl.tcl
