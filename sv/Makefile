# WINDOWS
setup:
	vivado -mode batch -source create_project.tcl

clean:
	powershell -Command "Remove-Item -Force -ErrorAction SilentlyContinue *.log,*.jou,*.wdb,*.str, *.pb, dfx_runtime.txt, *.xpr"
	powershell -Command "Remove-Item -Recurse -Force -ErrorAction SilentlyContinue .Xil, FPGA_SDR.cache, FPGA_SDR.gen, FPGA_SDR.hw, FPGA_SDR.ip_user_files, FPGA_SDR.srcs, FPGA_SDR.runs, FPGA_SDR.sim, FPGA_SDR.ioplanning, reports, xsim.dir"

%.sim:
	for %%f in (src\*.sv) do xvlog -sv %%f
	xvlog -sv ./tb/$*_tb.sv

	xvhdl -work xbip_utils_v3_0 ./FPGA_SDR.gen/sources_1/ip/low_pass_filter/hdl/xbip_utils_v3_0_vh_rfs.vhd
	xvhdl -work axi_utils_v2_0 ./FPGA_SDR.gen/sources_1/ip/low_pass_filter/hdl/axi_utils_v2_0_vh_rfs.vhd
	xvhdl -work xbip_pipe_v3_0 ./FPGA_SDR.gen/sources_1/ip/low_pass_filter/hdl/xbip_pipe_v3_0_vh_rfs.vhd
	xvhdl -work fir_compiler_v7_2_24 ./FPGA_SDR.gen/sources_1/ip/low_pass_filter/hdl/fir_compiler_v7_2_vh_rfs.vhd
	xvhdl -work xil_defaultlib ./FPGA_SDR.gen/sources_1/ip/low_pass_filter/sim/low_pass_filter.vhd

	xvhdl ./HarmoniCore.gen/sources_1/ip/div/sim/div.vhd
	xvlog ./HarmoniCore.gen/sources_1/ip/blk_mem/simulation/blk_mem_gen_v8_4.v

	copy .\FPGA_SDR.gen\sources_1\ip\low_pass_filter\low_pass_filter.mif .
	xelab -debug typical -relax $*_tb -s $*_sim -L xil_defaultlib -L fir_compiler_v7_2_24 -L xbip_pipe_v3_0 -L xbip_utils_v3_0 -L axi_utils_v2_0
	xsim $*_sim -gui -view ./waves/$*_sim.wcfg

synth:
	vivado -mode batch -source synth.tcl

impl:
	vivado -mode batch -source impl.tcl
