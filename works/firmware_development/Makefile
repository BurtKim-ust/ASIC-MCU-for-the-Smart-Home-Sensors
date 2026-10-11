# Copyright (c) 2026 Jonghyeok Kim
# This software is released under the MIT License.
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
# firmware code for motion sensor with zigbee communication

# Description: Makefile for IoT Motion Sensor Firmware (RV32E)
# Boot process:
#   1. Hardware boot ROM copies firmware from flash to SRAM
#   2. Firmware runs from SRAM at 0x20000000

# Toolchain Configuration
PREFIX = riscv32-unknown-elf-
CC = $(PREFIX)gcc
AS = $(PREFIX)as
LD = $(PREFIX)ld
OBJCOPY = $(PREFIX)objcopy
OBJDUMP = $(PREFIX)objdump
SIZE = $(PREFIX)size

# Target Configuration
TARGET = motion_sensor_minimal
ARCH = rv32e
ABI = ilp32e

# Compiler Flags
CFLAGS = -march=$(ARCH) -mabi=$(ABI) -Os -g
CFLAGS += -fno-optimize-sibling-calls
CFLAGS += -Wall -Wextra -Werror
CFLAGS += -ffreestanding -nostdlib -nostartfiles
CFLAGS += -fno-builtin -ffunction-sections -fdata-sections
CFLAGS += -mcmodel=medlow
CFLAGS += -DRISCV_E
CFLAGS += -DSIMULATION=1

# Assembler Flags
ASFLAGS = -march=$(ARCH) -mabi=$(ABI)

# Linker Flags
LDFLAGS = -T linker.ld -nostdlib -nostartfiles
LDFLAGS += -Wl,--gc-sections
LDFLAGS += -Wl,-Map,$(TARGET).map

# Source Files
C_SOURCES = motion_sensor_minimal.c
ASM_SOURCES = startup.S

# Object Files
C_OBJS = $(C_SOURCES:.c=.o)
ASM_OBJS = $(ASM_SOURCES:.S=.o)
OBJS = $(ASM_OBJS) $(C_OBJS)

# Output Files
ELF = $(TARGET).elf
BIN = $(TARGET).bin
HEX = $(TARGET).hex
VHEX = $(TARGET).vhex
DUMP = $(TARGET).dump
MAP = $(TARGET).map

# Build Rules
.PHONY: all clean disasm size verify verify-startup help

all: $(BIN) $(HEX) $(VHEX) $(DUMP) verify-startup
	@echo ""
	@echo "========================================================"
	@echo "          BUILD COMPLETE - READY FOR SIM"
	@echo "========================================================"
	@echo ""
	@$(SIZE) $(ELF)
	@echo ""
	@echo "Use $(VHEX) for simulation"
	@echo ""

# Link ELF file
$(ELF): $(OBJS) linker.ld
	@echo "Linking $@..."
	$(CC) $(CFLAGS) $(LDFLAGS) $(OBJS) -o $@

# Generate binary file (raw firmware image, loaded into flash)
$(BIN): $(ELF)
	@echo "Creating binary $@..."
	$(OBJCOPY) -O binary $< $@

# Generate hex file (Intel HEX format)
$(HEX): $(ELF)
	@echo "Creating hex $@..."
	$(OBJCOPY) -O ihex $< $@

# Generate Verilog hex file (for $readmemh in flash model)
$(VHEX): $(BIN) fix_vhex_endian.py
	@echo "Creating Verilog hex $(VHEX)..."
	@echo "Converting to continuous hex with endian fix..."
	@hexdump -ve '1/1 "%02x "' $(BIN) | \
		python3 fix_vhex_endian.py /dev/stdin $(VHEX)
	@echo "$(VHEX) ready (continuous + endian fixed)"
	@wc -l $(VHEX)

# Generate disassembly
$(DUMP): $(ELF)
	@echo "Creating disassembly $@..."
	$(OBJDUMP) -D -S $< > $@

# Compile C source files
%.o: %.c
	@echo "Compiling $<..."
	$(CC) $(CFLAGS) -c $< -o $@

# Assemble assembly source files
%.o: %.S
	@echo "Assembling $<..."
	$(CC) $(ASFLAGS) -c $< -o $@

# Clean build artifacts
clean:
	@echo "Cleaning..."
	rm -f $(OBJS) $(ELF) $(BIN) $(HEX) $(VHEX) $(DUMP) $(MAP)
	rm -f $(VHEX).tmp
	@echo "Clean complete!"

# Display size information
size: $(ELF)
	@echo "Memory usage:"
	@$(SIZE) -A -x $(ELF)
	@echo ""
	@echo "Section sizes:"
	@$(SIZE) -B $(ELF)

# Disassemble for inspection
disasm: $(DUMP)
	@less $(DUMP)

# Verify startup code
verify-startup: $(DUMP)
	@echo ""
	@echo "========================================================"
	@echo "        VERIFYING STARTUP (runs from SRAM)"
	@echo "========================================================"
	@echo ""
	@echo "Checking _start section (first 10 instructions):"
	@echo "------------------------------------------------"
	@$(OBJDUMP) -d $(ELF) | sed -n '/^20000000 <_start>/,/^[0-9a-f]* <.*>/p' | head -15
	@echo "------------------------------------------------"
	@echo ""
	@echo "Good signs:"
	@echo -n "  [1] Entry at 0x20000000: "
	@$(OBJDUMP) -d $(ELF) | grep -q "^20000000 <_start>" && echo "FOUND" || echo "MISSING"
	@echo -n "  [2] Setup stack (lui sp, 0x20002): "
	@$(OBJDUMP) -d $(ELF) | grep -q "lui.*sp,0x20002" && echo "FOUND" || echo "MISSING"
	@echo -n "  [3] Jump to main (jal.*main): "
	@$(OBJDUMP) -d $(ELF) | grep -q "jal.*<main>" && echo "FOUND" || echo "MISSING"
	@echo ""

# Verify standard instructions (wfi, mret)
verify: $(DUMP)
	@echo "Verifying standard RISC-V instructions..."
	@echo ""
	@echo "Looking for WFI (0x10500073):"
	@grep -n "10500073" $(DUMP) || echo "  Not found"
	@echo ""
	@echo "Looking for MRET (0x30200073):"
	@grep -n "30200073" $(DUMP) || echo "  Not found"
	@echo ""

# Show the beginning of the firmware
show-start: $(DUMP)
	@echo "First 50 instructions of firmware:"
	@$(OBJDUMP) -d $(ELF) | head -70

# Help
help:
	@echo "Available targets:"
	@echo "  all            - Build all output files (default)"
	@echo "  clean          - Remove all build artifacts"
	@echo "  size           - Display memory usage"
	@echo "  disasm         - View disassembly"
	@echo "  verify         - Check for standard RISC-V instructions"
	@echo "  verify-startup - Verify startup code"
	@echo "  show-start     - Show first 50 instructions"
	@echo "  help           - Display this help message"
	@echo ""
	@echo "Boot process:"
	@echo "  1. Boot ROM (hardwired) copies 8KB flash -> SRAM"
	@echo "  2. Jumps to 0x20000000"
	@echo "  3. _start sets SP, GP, calls main()"
	@echo "  4. Firmware runs from SRAM at full speed"
	@echo ""

# Dependencies
$(C_OBJS): motion_sensor_minimal.c
$(ASM_OBJS): startup.S
$(OBJS): linker.ld
$(VHEX): fix_vhex_endian.py
