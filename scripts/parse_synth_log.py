#!/usr/bin/env python3
import re
import sys

def parse_instance_areas(log_path):
    with open(log_path, 'r', errors='ignore') as f:
        lines = f.readlines()

    capture = False
    area_lines = []
    for line in lines:
        if "Report Instance Areas:" in line:
            capture = True
        if capture:
            area_lines.append(line)
            if "Report Cell Usage:" in line and len(area_lines) > 5:
                break
            if len(area_lines) > 200:
                break

    print("".join(area_lines))

if __name__ == '__main__':
    log_file = sys.argv[1] if len(sys.argv) > 1 else "build/synth_top.log"
    parse_instance_areas(log_file)
