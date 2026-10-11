source icc2_common_setup.tcl

set SDC_FILE ./results/$TOP.sdc
set SDC_VERSION 2.1
set FLOORPLAN floorplan/

# open library
open_lib $DESIGN_LIB_NAME

# read synthesized verilog file and set design
read_verilog $VERILOG_FILE -top $TOP
current_design
link

# read SDC constraints
read_sdc $SDC_FILE -version $SDC_VERSION

# read and setup floorplan
source $FLOORPLAN/fp.tcl

# configure scenario for optimization
set_scenario default -all

# set parasitics from TLU files to default corner
set_parasitic_parameters \
    -corners {default} \
    -early_spec $TLUPLUS_PATH/$MAX_TLUPLUS_FILE \
    -late_spec $TLUPLUS_PATH/$MIN_TLUPLUS_FILE

# create placements with floorplan cognizant of timings
create_placement -floorplan -timing_driven

# disable SCANDEF and optimize placement
set_app_options -name place.coarse.continue_on_missing_scandef -value true
place_opt
legalize_placement

# set strong timing optimization effort and optimize clock tree
set_app_options -name ccd.timing_effort -value high
clock_opt

# route optimization
route_opt
remove_redundant_shapes

# save
save_block
save_lib

# DRC checks
check_pg_drc
check_routes

## LVS check
check_lvs \
    -max_errors 0 \
    -check_zero_spacing_blockages true \
    -check_top_level_blockages true \
    -open_reporting detailed \
    -report_floating_pins true \
    -treat_terminal_as_voltage_source true 
