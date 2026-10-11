##############################################################################
#                                                                            #
#                            CLOCK DEFINITION                                #
#                                                                            #
##############################################################################

# Get configuration settings
source configuration.tcl

#reference clock is 32.768kHz
set REF_CLOCK_PERIOD 1000000000;

set SETUP_SKEW 0.09
set HOLD_SKEW 0.13
set GATER_SETUP 0.09
set GATER_HOLD 0.13
set CLK_TRANSITION_LIMIT 0.1
set SIGNAL_TRANSITION_LIMIT 0.1
set INPUT_DELAY 0.12
set OUTPUT_DELAY 0.12

create_clock -name     "clk"          \
    -period   "$REF_CLOCK_PERIOD"            \
    -waveform "0 [expr $REF_CLOCK_PERIOD/2]" \
    [get_ports clk]

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

#==========================#
#      OUTPUT PORTS        #
#==========================#
set_max_transition $SIGNAL_TRANSITION_LIMIT [get_designs $DESIGN]
set_max_fanout 6 $DESIGN

set_output_delay $OUTPUT_DELAY -clock [get_clocks] [all_outputs]
set_load [load_of tcbn65gplustc0d8/INVD8/I] [all_outputs]

#=========================#
#       INPUT PORTS       #
#=========================#

set_input_delay $INPUT_DELAY -clock [get_clocks] [remove_from_collection [all_inputs] clk]
set_driving_cell -lib_cell INVD1 [get_ports [all_inputs]]

set_false_path -from rst*
