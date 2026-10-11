/* 
 * Copyright (c) 2026 Jonghyeok Kim
 * This software is released under the MIT License.
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
 * firmware code for motion sensor with zigbee communication
 */

/* Description: Minimal Startup Code for RV32E
 * SKIPS .bss clearing for fast simulation
 */

.section .boot,"ax",@progbits
.globl _start
.globl boot_handler

_start:
boot_handler:
    # Initialize Stack Pointer to top of SRAM (0x20001FFC)

    lui sp, 0x20002             # sp = 0x20002000
    addi sp, sp, -4             # sp = 0x20001FFC (top of 8KB SRAM)
    
    # Initialize Global Pointer for data access optimization
    .option push
    .option norelax
    lui gp, 0x20001             # gp = 0x20001000
    addi gp, gp, -2048          # gp = 0x20000800 (__global_pointer$)
    .option pop
    
    /*
     * SKIP .data copy (data section size = 0 bytes)
     * SKIP .bss clear (would take forever - 8188 bytes!)
     * 
     * WARNING: All global and static variables will be UNINITIALIZED!
     * Only use:
     *   - Local variables (on stack) 
     *   - Direct hardware register access 
     *   - String literals in .rodata 
     * 
     * DO NOT use:
     *   - Global variables
     *   - Static variables 
     * 
     */
    
    # Jump to main()
    jal ra, main                # Call main function
    
    # If main returns, halt forever
halt:
    j halt                      # Infinite loop