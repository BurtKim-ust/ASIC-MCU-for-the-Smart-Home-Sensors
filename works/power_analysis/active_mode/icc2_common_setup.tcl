# Design library name for ICC II
set DESIGN_LIB_NAME icc2_design_lib

set TOP "riscvmulti"

# Synopsys path
set SYNOPSYS_ROOT "/afs/ee.cooper.edu/dist/synopsys/syn/S-2021.06-SP2"

# TSMC path
set TSMC_PATH "/afs/ee.cooper.edu/dist/cadence-tools/tsmc65/TSMCHOME/digital"

# Target cell library path (NDLM library)
set TARGETCELLLIB_PATH "$TSMC_PATH/Front_End/timing_power_noise/NLDM/tcbn65gplus_200a"

# Additional back-end Milkyway libraries
set ADDITIONAL_SEARCH_PATHS [list "$TARGETCELLLIB_PATH" \
    "$TSMC_PATH/Back_End/milkyway/tcbn65gplus_200a/cell_frame/tcbn65gplus/LM/*" \
    "$SYNOPSYS_ROOT/libraries/syn" \
    "./"]

# Target, standard, symbol, and reference liberty files
set TARGET_LIB "tcbn65gplustc0d8.db tcbn65gpluswc0d72.db tcbn65gplusbc0d88.db"
set STD_CELL_LIB_NAME "tcbn65gplustc0d8"
set SYMBOL_LIB "tcbn65gplustc0d8.db"
set REFERENCE_LIBS "$TSMC_PATH/Back_End/lef/tcbn65gplus_200a/lef/tcbn65gplus_9lmT2.lef"

# Technology files
set TECHFILE_PATH "$TSMC_PATH/Back_End/milkyway/tcbn65gplus_200a/techfiles"
set TECHFILE "tsmcn65_9lmT2.tf"
set TLUPLUS_PATH "$TECHFILE_PATH/tluplus"
set MAX_TLUPLUS_FILE "cln65g+_1p09m+alrdl_rcbest_top2.tluplus"
set MIN_TLUPLUS_FILE "cln65g+_1p09m+alrdl_rcworst_top2.tluplus"
set TECH2ITF_MAP_FILE "star.map_9M"

# Verilog synthesized file
set VERILOG_FILE ./results/$TOP.syn.v

