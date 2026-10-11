## Motion Sensor IoT Chip
# Project Description
ME Thesis: A Low-Power ASIC MCU Design Based on RISC-V RV32E for IoT Applications (2026)
Author: Jonghyeok Kim (rhdtn1244@gmail.com)
Advisor: Professor Jabeom Koo
Institution: The Cooper Union for the Advancement of Science and Art
Description: This thesis presents a custom RISC-V system-on-chip designed for a low-power motion sensor application. 
While the firmware demonstrates wireless light control through Zigbee, the modular hardware architecture is reusable 
for any battery-powered IoT sensor application by changing only the firmware C file. If you are a hardware engineer, 
feel free to modify the hardware (Verilog) for your application.
License: MIT

# Project Structure
Design RTL:          works/design/
Pre-Synth Sim:       works/pre_synthesis_sim/
Post-Synth Sim:      works/post_synthesis_sim/
Firmware:            works/firmware_development/
Synthesis:           works/synthesis/
Layout:              works/layout/

# Pre-Synthesis Simulation
Location: works/pre_synthesis_sim
Simulator: Icarus Verilog
Description: Behavioral RTL

Without waveform:
Mute UART bytes
iverilog -g2012 -DSIMULATION -o motion_sensor_sim testbench_pre_synth_silent.v riscvmulti.v
vvp motion_sensor_sim

Prints out UART bytes
iverilog -g2012 -DSIMULATION -o motion_sensor_sim testbench_pre_synth_silent_uart.v riscvmulti.v
vvp motion_sensor_sim

With waveform (generates VCD file for GTKWave):
iverilog -g2012 -DSIMULATION -DDUMP_VCD -o motion_sensor_sim testbench_pre_synth.v riscvmulti.v
vvp motion_sensor_sim
gtkwave pre_synth_sim.vcd &

Expected output:
- Boot completes at ~101 ms (404,766 CPU clock edges)
- UART prints: BOOT, T1-T5, F, NONET, RDY, DS
- PIR trigger at 121 ms
- Simulation ends at 1,121 ms on second Deep-sleep entry
- PIR sensing cycle: 500 clock edges

# Post-Synthesis Simulation
Location: works/post_synthesis_sim
Simulator: Synopsys VCS S-2021.09
Description: TSMC 65nm gate-level netlist

Run simulation:
Mute UART bytes
vcs testbench_post_synth.v motion_sensor_chip_top.syn.v /afs/ee.cooper.edu/dist/cadence-tools/tsmc65/TSMCHOME/digital/Front_End/verilog/tcbn65gplus_200a/tcbn65gplus.v +timescale+1ns/1ps

Prints out UART bytes
vcs testbench_post_synth_uart.v motion_sensor_chip_top.syn.v /afs/ee.cooper.edu/dist/cadence-tools/tsmc65/TSMCHOME/digital/Front_End/verilog/tcbn65gplus_200a/tcbn65gplus.v +timescale+1ns/1ps

Expected output:
- Identical to pre-synthesis except PIR sensing cycle - 495 clock edges (5 fewer due to gate-level timing)
- No X propagation

# Synthesis
Location: works/synthesis/
Tool: Synopsys Design Compiler S-2021.06-SP2
Process: TSMC 65nm GP+ (tcbn65gplus)
Analysis Corners: typical (0.8V), worst (0.72V), best (0.88V)

Run synthesis:
dc_shell -f synthesis.tcl

Key outputs:
- motion_sensor_chip_top.syn.v   (gate-level netlist)
- motion_sensor_chip_top.sdc     (timing constraints)
- reports/area.rpt               (area breakdown)
- reports/timing_max.rpt         (setup timing — all paths met)
- reports/timing_min.rpt         (hold timing — violations expected pre-layout)
- reports/power.rpt              (power estimates)

Synthesis results:
- Logic area (excluding SRAM): 26,583 um2
- SRAM (flip-flop based):      882,811 um2
- Total:                        909,394 um2

# Physical Layout
Location: works/layout/
Tool: Synopsys IC Compiler II (ICC2) S-2021.06-SP2
Target: TSMC 65nm GP+ (tcbn65gplus)

Run layout:
make layout

Layout results:
- Standard cell count: 14,155
- Cell area:           47,137 um2
- Core dimensions:     256.8 x 255.6 um
- Core area:           0.066 mm2

Note that SRAM is excluded from layout (would be replaced by compiled macro)

# Firmware Development
Location: works/firmware_development/
Toolchain: riscv32-unknown-elf-gcc
Target: RV32E, ILP32E ABI

Remove all generated binary files:
make clean

Generate firmware binary files:
make all

Build outputs:
- motion_sensor_minimal.elf    (ELF executable)
- motion_sensor_minimal.bin    (raw binary, 716 bytes)
- motion_sensor_minimal.vhex   (Verilog hex for simulation)
- motion_sensor_minimal.dump   (disassembly for debugging)
- motion_sensor_minimal.map    (linker memory map)

Firmware size: 716 bytes (179 words)

# Power Analysis Results (worst-case, 0.72V)
- Active mode:     72.46 uW
- Sleep mode:       7.65 uW
- Deep-sleep mode:  7.50 uW (leakage only)

# Credits
CPU Core Reference(PicoRV32): Clifford Wolf https://github.com/YosysHQ/picorv32/blob/main/picorv32.v
Layout Conversion: Amaan Rahman https://github.com/amaan4152/DVLSI-8bit-counter/tree/main