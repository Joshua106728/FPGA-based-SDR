# WINDOWS
setup:
	vivado -mode batch -source create_project.tcl

clean:
	powershell -Command "Remove-Item -Force -ErrorAction SilentlyContinue *.log,*.jou,*.wdb,*.str, *.pb"
	powershell -Command "Remove-Item -Recurse -Force -ErrorAction SilentlyContinue .Xil, HarmoniCore2.0.cache, HarmoniCore2.0.gen, HarmoniCore2.0.hw, HarmoniCore2.0.ip_user_files, HarmoniCore2.0.srcs"

%.sim:
	for %%f in (src\*.sv) do xvlog -sv %%f
	xvlog -sv ./tb/$*_tb.sv

# 	ADD IP BLOCKS HERE (use xvhdl for .vhd and xvlog for .v)

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
