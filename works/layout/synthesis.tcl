
#=============================================================================#
#                                Configuration                                #
#=============================================================================#

# Get configuration settings
source configuration.tcl

file mkdir ./$results
file mkdir ./$reports

#=============================================================================#
#                           Read technology library                           #
#=============================================================================#
source -echo -verbose ./library.tcl

#=============================================================================#
#                               Read design RTL                               #
#=============================================================================#
source -echo -verbose ./read.tcl

#=============================================================================#
#                           Set design constraints                            #
#=============================================================================#
source -echo -verbose ./constraints.tcl

set_clock_gating_style \
    -sequential_cell latch \
    -control_point before \
    -control_signal scan_enable \
    -positive_edge_logic \
    integrated:tcbn65gplustc0d8/CKLNQD2

#=============================================================================#
#              Set clock constraint                                           #
#=============================================================================#


#=============================================================================#
#              Set operating conditions & wire-load models                    #
#=============================================================================#
set_operating_conditions -max $LIB_WC_OPCON -max_library $LIB_WC_NAME \
                         -min $LIB_BC_OPCON -min_library $LIB_BC_NAME
 
set_wire_load_model -name "TSMC16K_Lowk_Conservative"
#=============================================================================#
#                                Synthesize                                   #
#=============================================================================#

# Prevent assignment statements in the Verilog netlist.
set_fix_multiple_port_nets -all -buffer_constants

# Run topdown synthesis
current_design $TOPLEVEL

# Set the compilation options
if {$DC_FLATTEN} {
   set_flatten true -effort $DC_FLATTEN_EFFORT
}
if {$DC_STRUCTURE} {
   set_structure true -timing $DC_STRUCTURE_TIMING -boolean $DC_STRUCTURE_LOGIC
}
if {$DC_PREFER_RUNTIME} {
   compile_prefer_runtime
}
set COMPILE_ARGS [list]
if {$DC_KEEP_HIER} {
   lappend COMPILE_ARGS "-no_autoungroup"
}
if {$DC_REG_RETIME} {
   set_optimize_registers -async_transform $DC_REG_RETIME_XFORM \
                          -sync_transform  $DC_REG_RETIME_XFORM
   lappend COMPILE_ARGS "-retime"
}
if {$DC_BOUNDARY_OPTIMIZATION eq 0} {
    lappend COMPILE_ARGS "-no_boundary_optimization"
}
if {$DC_SEQ_OUTPUT_INVERSION eq 0} {
    lappend COMPILE_ARGS "-no_seq_output_inversion"
}
if {$DC_EXACT_MAP} {
    lappend COMPILE_ARGS "-exact_map"
}

#=============================================================================#
#                            Synthesis                                        #
#=============================================================================#

# Check for design errors
check_design -summary
check_design > "./$reports/check_design.rpt"

# Compile, first pass
#compile_ultra $COMPILE_ARGS
compile_ultra

# Second pass, if enabled
if {$DC_COMPILE_ADDITIONAL} {
   compile_ultra -incremental
}

#=============================================================================#
#                            Reports generation                               #
#=============================================================================#

report_constraints -all_violators -verbose > "./$reports/constraints.rpt"
report_timing -path end  -delay max -max_paths 200 -nworst 2 > "./$reports/timing.max.rpt"
report_timing -path full -delay max -max_paths 5   -nworst 2 > "./$reports/timing.max.fullpath.rpt"
report_timing -path end  -delay min -max_paths 200 -nworst 2 > "./$reports/timing.min.rpt"
report_timing -path full -delay min -max_paths 5   -nworst 2 > "./$reports/timing.min.fullpath.rpt"
report_area -physical -hier -nosplit   > "./$reports/area.rpt"
report_power -hier -nosplit            > "./$reports/power.hier.rpt"
report_power -verbose -nosplit         > "./$reports/power.rpt"

#=============================================================================#
#          Dump gate level netlist, final DDC file                            #
#=============================================================================#
current_design $TOPLEVEL

write -hierarchy -format verilog -output "./$results/$TOPLEVEL.syn.v"
write -hierarchy -format ddc     -output "./$results/$TOPLEVEL.ddc"

# === dump other design files (sdc, db, sdf)
write_sdc                               "./$results/$TOPLEVEL.sdc"
write -h $TOPLEVEL -output              "./$results/$TOPLEVEL.db"
write_sdf -context verilog -version 1.0 "./$results/$TOPLEVEL.sdf"



