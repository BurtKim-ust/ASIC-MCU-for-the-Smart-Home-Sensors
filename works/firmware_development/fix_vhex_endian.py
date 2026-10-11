#!/usr/bin/env python3
"""
Copyright (c) 2026 Jonghyeok Kim
This software is released under the MIT License.
Description: Script to fix byte order in .vhex files.
1. Convert byte addresses to word addresses (divide by 4)
2. Group bytes into 32-bit words
3. Reverse byte order (little-endian → big-endian)
"""

import sys

def fix_vhex(input_file, output_file):
    with open(input_file, 'r') as f_in, open(output_file, 'w') as f_out:
        current_bytes = []
        
        for line in f_in:
            line = line.strip()
            
            # Handle address lines
            if line.startswith('@'):
                if current_bytes:
                    while len(current_bytes) >= 4:
                        word = ''.join(reversed(current_bytes[0:4]))
                        f_out.write(f'{word}\n')
                        current_bytes = current_bytes[4:]
                
                byte_addr = int(line[1:], 16)
                word_addr = byte_addr // 4
                f_out.write(f'@{word_addr:08x}\n')
                current_bytes = []
            
            # Handle data lines with space-separated bytes
            elif line and not line.startswith('//'):
                bytes_in_line = line.split()
                current_bytes.extend(bytes_in_line)
                
                while len(current_bytes) >= 4:
                    word = ''.join(reversed(current_bytes[0:4]))
                    f_out.write(f'{word}\n')
                    current_bytes = current_bytes[4:]
        
        if current_bytes:
            while len(current_bytes) < 4:
                current_bytes.append('00')
            word = ''.join(reversed(current_bytes[0:4]))
            f_out.write(f'{word}\n')

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input.vhex.tmp> <output.vhex>")
        sys.exit(1)
    
    fix_vhex(sys.argv[1], sys.argv[2])
    print(f' Fixed byte order: {sys.argv[2]}')