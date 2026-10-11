#!/bin/bash -ix
#
# CMD Line Arguments
# ------------------
# $1 : workflow mode
# $2 : simulation ID
# $3 : testbench simulation termination delay
#
# name of DUT
FILENAME="counter"

#tcbn65gplus absolute path
TCBN65GPLUS_PATH=

# vcs cmd flags
VCS_FLAGS=(+compsdf +neg_tchk)

SRC=./src
RES=./results
source ~/.bashrc

case $1 in 
    "PRE_SYN")
        printf '\n\t\t\e[1;35m%s\e[m\n' "========== PRE-SYNTHESIS =========="
        perl $SRC/config_simvcs.pl $SRC/testbench.v "${2}_PRESYN" $3
        vcs $SRC/testbench.v $SRC/${FILENAME}.v ${VCS_FLAGS[@]: 1}
        ./simv
        ;;

    "POST_SYN")
        printf '\n\t\t\e[1;35m%-6s\e[m\n' "========== POST-SYNTHESIS =========="
        dc_shell-xg-t -topographic -x "source ./synthesis.tcl; exit"
        perl $SRC/config_simvcs.pl $SRC/testbench.v "${2}_POSTSYN" $3
        vcs $SRC/testbench.v $RES/${FILENAME}.syn.v $TCBN65GPLUS_PATH ${VCS_FLAGS[@]}
        ./simv
        perl src/config_pins.pl $RES/${FILENAME}.syn.v
        ;;
    
    "ICC")
        icc2_shell -x "source set_up.tcl; source optimization.tcl"
        ;;
esac
