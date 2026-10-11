##############################################################################
#                                                                            #
#                            CLOCK DEFINITION                                #
#                                                                            #
##############################################################################

# Get configuration settings
source configuration.tcl

#reference clock is 4MHz, 32kHz
set REF_CLOCK_PERIOD 250;
set REF_CLOCK_PERIOD2 30518;

set SETUP_SKEW 0.19
set HOLD_SKEW 0.23
set GATER_SETUP 0.04
set GATER_HOLD 0.15
set CLK_TRANSITION_LIMIT 0.14
set SIGNAL_TRANSITION_LIMIT 0.14
set INPUT_DELAY 0.16
set OUTPUT_DELAY 0.16

create_clock -name     "clk_4mhz"          \
    -period   "$REF_CLOCK_PERIOD"            \
    -waveform "0 [expr $REF_CLOCK_PERIOD/2]" \
    [get_ports clk_4mhz]

create_clock -name     "clk_32khz"          \
    -period   "$REF_CLOCK_PERIOD2"            \
    -waveform "0 [expr $REF_CLOCK_PERIOD2/2]" \
    [get_ports clk_32khz]

create_generated_clock -name "clk_cpu" \
    -source [get_ports clk_4mhz]       \
    -divide_by 1                        \
    [get_pins u_pmu/clk_cpu]

set_clock_groups -asynchronous \
    -group [get_clocks clk_4mhz]  \
    -group [get_clocks clk_32khz]

##############################################################################
#                                                                            #
#                          BOUNDARY TIMINGS                                  #
#                                                                            #
##############################################################################
#==========================#
#          GLOBAL          #
#==========================#
set_critical_range 0.05 $current_design

#==========================#
#          CLOCK           #
#==========================#
set_clock_uncertainty -setup $SETUP_SKEW [get_clocks]
set_clock_uncertainty -hold $HOLD_SKEW [get_clocks]

set_clock_transition $CLK_TRANSITION_LIMIT [get_clocks]
set_fix_hold [get_clocks]

# Clock gating checks for the ICG latch in PMU
set_clock_gating_check -setup $GATER_SETUP -hold $GATER_HOLD [get_clocks clk_4mhz]

#==========================#
#      OUTPUT PORTS        #
#==========================#
set_max_transition $SIGNAL_TRANSITION_LIMIT [get_designs $DESIGN]
set_max_fanout 6 $DESIGN
set_output_delay $OUTPUT_DELAY -clock clk_cpu [get_ports {uart0_tx}]
set_output_delay $OUTPUT_DELAY -clock clk_cpu [get_ports {gpio[*]}]
set_output_delay $OUTPUT_DELAY -clock clk_cpu [get_ports {debug_state[*] debug_clk_cpu_en debug_cpu_trap}]
set_output_delay $OUTPUT_DELAY -clock clk_4mhz [get_ports {flash_spi_clk flash_spi_cs_n flash_spi_mosi}]
set_load [load_of tcbn65gplustc0d8/INVD8/I] [all_outputs]


#=========================#
#       INPUT PORTS       #
#=========================#

set_input_delay $INPUT_DELAY -clock clk_4mhz  [get_ports {clk_32khz}] -add_delay
set_input_delay $INPUT_DELAY -clock clk_4mhz  [get_ports {flash_spi_miso}]
set_input_delay $INPUT_DELAY -clock clk_cpu    [get_ports {uart0_rx}]
set_input_delay $INPUT_DELAY -clock clk_cpu    [get_ports {gpio[*]}]
set_driving_cell -lib_cell INVD1 [all_inputs]

##############################################################################
#                         ASYNCHRONOUS PATHS                                 #
##############################################################################

# Reset is asynchronous (has internal synchronizer: reset_sync)
set_false_path -from [get_ports "rst*" -quiet]

# PIR sensor is a fully asynchronous input (has synchronizer chain in PMU)
set_false_path -from [get_ports pir_sensor]

# UART RX is asynchronous (has double-flop synchronizer in uart module)
set_false_path -from [get_ports uart0_rx]
