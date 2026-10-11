# Define libraries
source icc2_common_setup.tcl

set SDC_FILE ./results/$TOP.sdc
set SDC_VERSION 2.1

# Set search path
set_app_var search_path [concat $search_path $ADDITIONAL_SEARCH_PATHS]

# Set the target libraries
#set_app_var target_library "$TARGET_LIB"
set_app_var link_library "* $TARGET_LIB"

# Create a design lib and attach the reference lib and techfiles
if {[file isdirectory $DESIGN_LIB_NAME]} {
   file delete -force $DESIGN_LIB_NAME
}
create_lib $DESIGN_LIB_NAME -ref_libs $REFERENCE_LIBS -tech $TECHFILE_PATH/$TECHFILE

open_lib $DESIGN_LIB_NAME

# Read Verilog netlist files. Design name is set to top module name
read_verilog $VERILOG_FILE -top $TOP
current_design
link

# Set up parasitic model files in TLUPlus format
read_parasitic_tech \
   -tlup $TLUPLUS_PATH/$MAX_TLUPLUS_FILE \
   -layermap $TLUPLUS_PATH/$TECH2ITF_MAP_FILE
read_parasitic_tech \
   -tlup $TLUPLUS_PATH/$MIN_TLUPLUS_FILE \
   -layermap $TLUPLUS_PATH/$TECH2ITF_MAP_FILE

# Read sdc file
read_sdc $SDC_FILE -version $SDC_VERSION

# Initial floorplanning
initialize_floorplan

# Save design
save_block
save_lib

# Gather Bus in/output pins and define new variables
# Set how to deploy Bus in/output pins
report_port_buses

# Set contraints for pins. Refer set_individual_pin_constraints for detail placements
# Set additional constraints for pins such that all the input pins are deployed at the left side and all the output pins to right side.
set_individual_pin_constraints \
   -ports {clk down rst_n VDD VSS} \
   -side 1
set_individual_pin_constraints \
   -ports {count[*]} \
   -side 3

report_block_pin_constraints
check_pre_pin_placement -self

# Placing the ports according to the constraints defined above.
place_pins -self

#Define the power and ground nets
resolve_pg_nets

#Connect the power and ground nets to power and ground pins
connect_pg_net -automatic

#No need to define VIA master rules(ex. ContactCode) because they are already defined at .tf file in the Back_End milkyway library.
#Create ring pattern
create_pg_ring_pattern \
    PG_RING \
    -side_layer {{{side: 1 2 3 4}{layer: M9}}} \
    -corner_bridge true

set_pg_strategy \
   PG_RING \
   -pattern {{name: PG_RING}{nets: {VDD VSS}}} \
   -design_boundary

#Set above set-ups as one strategy. Use this option when the pattern will be used again at other blocks. If you work for only one block, no need to use.
#Save above mesh power setting as one strategy. For some reason, ICC2 does not take parameters. So, please remove the last parameter set-up
create_pg_mesh_pattern \
   PG_MESH \
   -layers {{{horizontal_layer: M8}{pitch: 3.6}{spacing: interleaving}} \
   {{vertical_layer: M6}{pitch: 3.6}{spacing: interleaving}}} \
   -via_rule {{{layers: M6}{layers: M8}}}

set_pg_strategy \
   PG_MESH_STRAT \
   -pattern {{name: PG_MESH}{nets: {VDD VSS}}} \
   -extension { \
      {{nets: VDD}{layers: M8 M6}{stop: outermost_ring}} \
      {{nets: VSS}{layers: M8 M6}{stop: outermost_ring}} \
   } \
   -design_boundary

#Standard cell rail pattern specifies the metal layers, rail width and rail offset to use to create the power and ground rails for the standard cell rows
#Set stretagy related with above pattern
create_pg_std_cell_conn_pattern std_rail_pat_0
set_pg_strategy \
   STD_CELL_RAIL \
   -pattern {{name: std_rail_pat_0}{nets: {VDD VSS}}} \
   -core

# compile strategies
set_app_options \
   -name plan.pgroute.treat_cell_type_as_macro -value true
set_app_options \
   -name plan.pgroute.treat_fat_blockage_as_fat_metal -value false
compile_pg

# verify PG connections
check_pg_connectivity

save_block
save_lib

write_floorplan

