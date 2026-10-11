/* 
    Copyright (c) 2026 Jonghyeok Kim
    This software is released under the MIT License.
    Linker Script for RV32E Motion Sensor Firmware
 
    Boot process:
    1. Hardware boot ROM copies 8KB from flash to SRAM
    2. Boot ROM jumps to 0x20000000
    3. Firmware runs entirely from SRAM at full speed
 
   Memory Layout:
    Flash: 0x08000000 - 0x0800FFFF (64KB) - storage only, accessed via SPI
    SRAM:  0x20000000 - 0x20001FFF (8KB)  - firmware executes here
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY {
    sram  (rwx) : ORIGIN = 0x20000000, LENGTH = 8K
}

SECTIONS {
    /* Everything goes to SRAM - boot ROM copies it from flash */
    
    .text 0x20000000 : {
        KEEP(*(.boot))       /* startup code first */
        *(.text.unlikely .text.*_unlikely)
        *(.text.startup .text.startup.*)
        *(.text .text.* .stub .gnu.linkonce.t.*)
        . = ALIGN(4);
        PROVIDE(__etext = .);
    } > sram
    
    .rodata : {
        *(.rodata .rodata.* .gnu.linkonce.r.*)
        *(.srodata .srodata.*)
        . = ALIGN(4);
    } > sram
    
    .data : {
        __data_start = .;
        *(.data .data.* .gnu.linkonce.d.*)
        *(.sdata .sdata.* .gnu.linkonce.s.*)
        . = ALIGN(4);
        __data_end = .;
    } > sram
    
    .bss : {
        __bss_start = .;
        *(.sbss .sbss.* .gnu.linkonce.sb.*)
        *(.bss .bss.* .gnu.linkonce.b.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > sram
    
    /* Stack: 2KB */
    .stack (NOLOAD) : {
        . = ALIGN(16);
        __stack_bottom = .;
        . = . + 0x800;
        __stack_top = .;
    } > sram
    
    /* Global pointer */
    __global_pointer$ = MIN(__data_start + 0x800,
                            MAX(__data_start + 0x800, __bss_end - 0x800));
    
    PROVIDE(__heap_start = __bss_end);
    PROVIDE(__heap_end = __stack_bottom);
    
    /DISCARD/ : {
        *(.note .note.*)
        *(.eh_frame .eh_frame.*)
        *(.comment)
        *(.riscv.attributes)
    }
}

PROVIDE(__sram_size = LENGTH(sram));
PROVIDE(__stack_size = __stack_top - __stack_bottom);
