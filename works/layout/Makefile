SCRIPT=exec_workflow.sh

.PHONY:
	init pre post layout clean

init: clean
	mkdir logs logs/misc dumpster dumpster/cmd_outs

pre: clean
	source ~/.bashrc && ./$(SCRIPT) PRE_SYN $(EXP) $(TIME)

post: clean
	source ~/.bashrc && ./$(SCRIPT) POST_SYN $(EXP) $(TIME)

layout: clean
	source ~/.bashrc && ./$(SCRIPT) ICC

clean:
ifneq (,$(wildcard ./*.log*))
	@mv -f *.log* logs/misc/
endif
ifneq (,$(wildcard ./*_output.txt))
	@mv -f *_output.txt dumpster/cmd_outs/
endif
	@rm -f simv
	@rm -f default-*
	@rm -rf floorplan/
	@rm -rf icc2_design_lib/
	
