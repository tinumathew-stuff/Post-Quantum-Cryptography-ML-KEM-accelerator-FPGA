#!/usr/bin/env python3
import os
import re
import glob

RTL_FILES = sorted(glob.glob("mlkem_hpka_accelerator/*/rtl/*.*"))

def analyze_file(filepath):
    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()
        lines = content.splitlines()

    stats = {
        'filepath': filepath,
        'lines': len(lines),
        'multipliers': [],
        'dynamic_shifts': [],
        'arrays': [],
        'case_statements': 0,
        'dsp_attributes': [],
        'ram_attributes': [],
        'divisions_modulos': [],
    }

    # Find arrays e.g. reg [W-1:0] mem [N-1:0] or logic [W-1:0] mem [N-1:0]
    array_pattern = re.compile(r'(reg|logic|wire)\s*(\[[^\]]+\])?\s*([a-zA-Z0-9_]+)\s*\[([^\]]+)\];')
    # Multiplier pattern
    mul_pattern = re.compile(r'[^/*]\*[^/*]')
    # Division or modulo
    div_pattern = re.compile(r'[^/]/[^/]|%')
    # Dynamic shift pattern: variable on right of >> or <<
    # e.g., >> count, << shift, etc. (not constant numbers)
    shift_pattern = re.compile(r'(<<|>>)\s*([a-zA-Z_][a-zA-Z0-9_]*)')

    for i, line in enumerate(lines, 1):
        clean_line = line.split('//')[0].strip()
        if not clean_line:
            continue

        # Check arrays
        m = array_pattern.search(clean_line)
        if m:
            stats['arrays'].append((i, clean_line))

        # Check multipliers
        if mul_pattern.search(clean_line):
            stats['multipliers'].append((i, clean_line))

        # Check division / mod
        if div_pattern.search(clean_line):
            stats['divisions_modulos'].append((i, clean_line))

        # Check shifts
        for sm in shift_pattern.finditer(clean_line):
            stats['dynamic_shifts'].append((i, sm.group(0), clean_line))

        if 'case' in clean_line and '(' in clean_line:
            stats['case_statements'] += 1

        if 'use_dsp' in clean_line:
            stats['dsp_attributes'].append((i, clean_line))

        if 'ram_style' in clean_line:
            stats['ram_attributes'].append((i, clean_line))

    return stats

def main():
    print("=" * 80)
    print("RTL STATIC COMPLEXITY & RESOURCE ANALYSIS")
    print("=" * 80)

    for fp in RTL_FILES:
        st = analyze_file(fp)
        print(f"\nFILE: {st['filepath']} (Lines: {st['lines']})")
        if st['arrays']:
            print(f"  [ARRAYS / REGISTER FILES] ({len(st['arrays'])} found):")
            for line_no, text in st['arrays'][:10]:
                print(f"    L{line_no}: {text}")
            if len(st['arrays']) > 10:
                print(f"    ... and {len(st['arrays']) - 10} more")
        
        if st['dynamic_shifts']:
            print(f"  [DYNAMIC SHIFTS] ({len(st['dynamic_shifts'])} found):")
            for line_no, shift, text in st['dynamic_shifts'][:10]:
                print(f"    L{line_no} [{shift}]: {text}")
            if len(st['dynamic_shifts']) > 10:
                print(f"    ... and {len(st['dynamic_shifts']) - 10} more")

        if st['multipliers']:
            print(f"  [MULTIPLIERS (*)] ({len(st['multipliers'])} found):")
            for line_no, text in st['multipliers'][:10]:
                print(f"    L{line_no}: {text}")
            if len(st['multipliers']) > 10:
                print(f"    ... and {len(st['multipliers']) - 10} more")

        if st['divisions_modulos']:
            print(f"  [DIV / MOD] ({len(st['divisions_modulos'])} found):")
            for line_no, text in st['divisions_modulos'][:5]:
                print(f"    L{line_no}: {text}")

        if st['dsp_attributes']:
            print(f"  [DSP PRAGMAS]: {st['dsp_attributes']}")
        if st['ram_attributes']:
            print(f"  [RAM PRAGMAS]: {st['ram_attributes']}")

if __name__ == '__main__':
    main()
