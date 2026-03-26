# WINDOWS
setup:
	vivado -mode batch -source create_project.tcl

clean:
	powershell -Command "Remove-Item -Force -ErrorAction SilentlyContinue *.log,*.jou,*.wdb,*.str, *.pb"
	powershell -Command "Remove-Item -Recurse -Force -ErrorAction SilentlyContinue .Xil, FPGA_SDR.cache, FPGA_SDR.gen, FPGA_SDR.hw, FPGA_SDR.ip_user_files, FPGA_SDR.srcs"

%.sim:
	for %%f in (src\*.sv) do xvlog -sv %%f
	xvlog -sv ./tb/$*_tb.sv

# 	ADD IP BLOCKS HERE (use xvhdl for .vhd and xvlog for .v)
	xvlog ./FPGA_SDR.gen/sources_1/ip/fifo/sim/fifo.v
	xvlog ./FPGA_SDR.gen/sources_1/ip/fifo/simulation/fifo_generator_vlog_beh.v
	xvlog ./FPGA_SDR.gen/sources_1/ip/fifo/hdl/fifo_generator_v13_2_rfs.v
	xvhdl ./FPGA_SDR.gen/sources_1/ip/fifo/hdl/fifo_generator_v13_2_rfs.vhd

	xelab -debug typical $*_tb -s $*_sim
	xsim $*_sim -gui -view ./waves/$*_sim.wcfg

# MAC
# setup:
# 	vivado -mode batch -source create_project.tcl
# clean:
# 	rm -rf *.wdb *.jou *.log *.pb *.str
# %.sim:
# 	for %%f in (src\*.sv) do xvlog -sv %%f
# 	xvlog -sv ./tb/$*_tb.sv
# 	ADD ANY IP BLOCKS HERE
# 	xelab -debug typical $*_tb -s $*_sim
# 	xsim $*_sim -gui -view ./waves/$*_sim.wcfg
