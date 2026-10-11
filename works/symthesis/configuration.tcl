# ===== Design libraries =====
set DESIGN_MW_LIB_NAME "design_lib"

# ===== Logic libraries =====
set SYNOPSYS_ROOT "/afs/ee.cooper.edu/dist/synopsys/syn/S-2021.06-SP2"
set TSMC_PATH "/afs/ee.cooper.edu/dist/cadence-tools/tsmc65/TSMCHOME/digital"
set TARGETCELLLIB_PATH "$TSMC_PATH/Front_End/timing_power_noise/NLDM/tcbn65gplus_200a"
set ADDITIONAL_SEARCH_PATHS [list "$TARGETCELLLIB_PATH" \
   "$TSMC_PATH/Back_End/milkyway/tcbn65gplus_200a/cell_frame/tcbn65gplus/LM/*" \
   "$SYNOPSYS_ROOT/libraries/syn" \
   "./"]

set TARGET_LIBS [list \
   "tcbn65gplustc0d8.db" \
   "tcbn65gplusbc0d88.db" \
   "tcbn65gpluswc0d72.db" \
]

set STD_CELL_LIB_NAME "tcbn65gplustc0d8"
set SYMBOL_LIB "tcbn65gplustc0d8.db"
set SYNOPSYS_SYNTHETIC_LIB "dw_foundation.sldb"
set MW_REFERENCE_LIBS "$TSMC_PATH/Back_End/milkyway/tcbn65gplus_200a/frame_only/tcbn65gplus"

# Typical case library
set LIB_TC_FILE "tcbn65gplustc0d8.db"
set LIB_TC_NAME "tcbn65gplustc0d8"

# Worst case library
set LIB_WC_FILE "tcbn65gpluswc0d72.db"
set LIB_WC_NAME "tcbn65gpluswc0d72"

# Best case library
set LIB_BC_FILE "tcbn65gplusbc0d88.db"
set LIB_BC_NAME "tcbn65gplusbc0d88"

# Operating conditions
set LIB_TC_OPCON "NC0D8COM"
set LIB_WC_OPCON "WC0D72COM"
set LIB_BC_OPCON "BC0D88COM"

# ===== Techology files =====
set MW_TECHFILE_PATH "$TSMC_PATH/Back_End/milkyway/tcbn65gplus_200a/techfiles"
set MW_TLUPLUS_PATH "$MW_TECHFILE_PATH/tluplus"
set MW_TECHFILE "tsmcn65_9lmT2.tf"
set MAX_TLUPLUS_FILE "cln65g+_1p09m+alrdl_rcbest_top2.tluplus"
set MIN_TLUPLUS_FILE "cln65g+_1p09m+alrdl_rcworst_top2.tluplus"
set TECH2ITF_MAP_FILE "star.map_9M"

# ================================================================================
# FUNCTIONAL CONFIG
# ================================================================================
set DESIGN "motion_sensor_chip_top"
set PROJECT_DIR "/afs/ee.cooper.edu/user/j/jonghyeok.kim/DVLSI/thesis_final"
# Place your path where your source code exits

# Reduce runtime
set DC_PREFER_RUNTIME 0

# Preserve design hierarchy
set DC_KEEP_HIER 1

# Register retiming
set DC_REG_RETIME 0
set DC_REG_RETIME_XFORM "multiclass"

# Logic flattening
set DC_FLATTEN 0
set DC_FLATTEN_EFFORT "medium"

# Logic structuring
set DC_STRUCTURE 1
set DC_STRUCTURE_TIMING "true"
set DC_STRUCTURE_LOGIC  "true"

# Boundary_optimization wanted?
set DC_BOUNDARY_OPTIMIZATION 0

# Sequential output inversion allowed?
set DC_SEQ_OUTPUT_INVERSION 0

# Exact map
set DC_EXACT_MAP 0

# Do an additional incremental compile for better results
set DC_COMPILE_ADDITIONAL 0

# ==========================================================================
# RESULT GENERATION AND REPORTING
# ==========================================================================

set results "results"
set reports "reports"

