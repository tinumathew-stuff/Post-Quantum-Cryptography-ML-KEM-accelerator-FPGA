#!/usr/bin/env python3
import sys

with open("mlkem_hpka_accelerator/accel_core/rtl/mlkem_keygen_top.sv", "r") as f:
    lines = f.readlines()

print(f"Total lines in mlkem_keygen_top.sv: {len(lines)}")
for i, line in enumerate(lines):
    if any(k in line for k in ["reg [", "logic ["]) and "[" in line.split(";")[0] and line.strip().endswith(";"):
        parts = line.strip().split()
        if len(parts) >= 3 and parts[-1].endswith(";"):
            # check if 2D array
            if line.count("[") >= 2:
                print(f"L{i+1}: {line.strip()}")
