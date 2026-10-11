
##############################################################################
#                                                                            #
#                            SPECIFY LIBRARIES                               #
#                                                                            #
##############################################################################

# Get configuration settings
source configuration.tcl

# Set library search path
set_app_var search_path [concat $search_path $ADDITIONAL_SEARCH_PATHS]

# Set the target libraries
set_app_var target_library "$TARGET_LIBS"

# Set symbol library, link path, and link libs
set_app_var symbol_library $SYMBOL_LIB
set_app_var link_path [list "*" $TARGET_LIBS]
set_app_var link_library "* $TARGET_LIBS $SYNOPSYS_SYNTHETIC_LIB"

# Create a MW design lib and attach the reference lib and techfiles
if {[file isdirectory $DESIGN_MW_LIB_NAME]} {
   file delete -force $DESIGN_MW_LIB_NAME
}
create_mw_lib $DESIGN_MW_LIB_NAME \
   -technology $MW_TECHFILE_PATH/$MW_TECHFILE \
   -mw_reference_library [list $MW_REFERENCE_LIBS]
open_mw_lib $DESIGN_MW_LIB_NAME

# Set up tlu_plus files (for virtual route and post route extraction)
set_tlu_plus_files \
  -max_tluplus $MW_TLUPLUS_PATH/$MAX_TLUPLUS_FILE \
  -min_tluplus $MW_TLUPLUS_PATH/$MIN_TLUPLUS_FILE \
  -tech2itf_map $MW_TLUPLUS_PATH/$TECH2ITF_MAP_FILE

