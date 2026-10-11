##############################################################################
#                                                                            #
#                               READ DESIGN RTL                              #
#                                                                            #
##############################################################################

# Get configuration settings
source configuration.tcl

set BASE "$PROJECT_DIR/src"
set TOPLEVEL "$DESIGN"

set RTL_SOURCE_FILES "\
$BASE/counter.v"

set_svf ./$results/$TOPLEVEL.svf
define_design_lib WORK -path ./WORK
read_file -format verilog $RTL_SOURCE_FILES

link
current_design $TOPLEVEL


