# DVLSI-8bit-counter
![final_layout](https://user-images.githubusercontent.com/63811852/205077164-edbbc8ea-eb05-4713-a500-fb5cbb023749.png)

## Abstract
Constructed 8-bit counter with Verilog HDL and implemented with 65nm CMOS technology. Utilized Synopsys tools such as `vcs`, `dc_shell`, and `icc2_shell`. Verilog simulations where generated with `vcs` and `dc_shell` was used for synthesis. Positive slack is achieved for maximum/minimum full path and total number of instances is 19. Given the synthesized Verilog, `icc2_shell` was used to perform design planning to generate the floorplan with appropriate PG planning. Moreover, placement optimization, clock-tree-synthesis, and routing optimization were conducted. Final layout passes all LVS and DRC checks. 

## Start
Create necessary directories: 
  - `dumpster/`: store `.vcd` waveform files after `vcs`
  - `logs/`: store any log files and command history logs of `dc_shell` and `icc2_shell`
```
make init
```
## Pre-Synthesis Simulation
The `ID` parameter is the experiment ID so that the generated VCD files, in the `dumpster/` directory, for pre-synthesis and post-synthesis will be tagged with a unique ID $ID_NUM.
The `TIME` parameter is the duration of the simulation to be executed. 
```
make pre ID=$ID_NUM TIME=$SIMULATION_DURATION
```

## Post-Synthesis Simulation
```
make post ID=$ID_NUM TIME=$SIMULATION_DURATION
```

## Layout (`floorplan`, `place_opt`, `clock_opt`, and `route_opt`)
```
make layout
```

## Clean Setup
```
make clean
```
