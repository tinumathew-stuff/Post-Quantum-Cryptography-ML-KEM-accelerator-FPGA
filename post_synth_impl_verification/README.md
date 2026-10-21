# Post-Synthesis & Post-Implementation Gate-Level Verification Suite

This directory contains the complete automated toolflow, testbenches, constraints, synthesis/implementation scripts, and Known Answer Test (KAT) vectors for gate-level functional verification of the unified ML-KEM accelerator (`mlkem_keygen_top`) across all NIST FIPS 203 operational modes and security parameters.

---

## 📋 Verification Overview

| Parameter Set | Security Level | Operation | Post-Synthesis Sim | Post-Implementation Sim | Latency (Cycles) | Verification Status |
| :--- | :--- | :--- | :---: | :---: | :---: | :---: |
| **ML-KEM-512** | Category 1 ($k=2$) | KeyGen | **PASS** | **PASS** | 1,369 | 100% Bit-Exact |
| **ML-KEM-512** | Category 1 ($k=2$) | Encapsulation | **PASS** | **PASS** | 1,665 | 100% Bit-Exact |
| **ML-KEM-512** | Category 1 ($k=2$) | Decapsulation | **PASS** | **PASS** | 2,471 | 100% Bit-Exact |
| **ML-KEM-768** | Category 3 ($k=3$) | KeyGen | **PASS** | **PASS** | 2,056 | 100% Bit-Exact |
| **ML-KEM-768** | Category 3 ($k=3$) | Encapsulation | **PASS** | **PASS** | 2,411 | 100% Bit-Exact |
| **ML-KEM-768** | Category 3 ($k=3$) | Decapsulation | **PASS** | **PASS** | 3,414 | 100% Bit-Exact |
| **ML-KEM-1024** | Category 5 ($k=4$) | KeyGen | **PASS** | **PASS** | 2,743 | 100% Bit-Exact |
| **ML-KEM-1024** | Category 5 ($k=4$) | Encapsulation | **PASS** | **PASS** | 3,412 | 100% Bit-Exact |
| **ML-KEM-1024** | Category 5 ($k=4$) | Decapsulation | **PASS** | **PASS** | 4,358 | 100% Bit-Exact |

---

## 📁 Directory Structure

```
post_synth_impl_verification/
├── build/                      # Exported gate-level functional simulation netlists & logs
│   ├── post_synth_netlist.v    # Post-synthesis structural netlist
│   ├── post_impl_netlist.v     # Post-implementation placed-and-routed structural netlist
│   └── vivado.log              # Synthesis and implementation run log
├── constraints.xdc             # 450 MHz clock constraint (T_clk = 2.222 ns)
├── logs/                       # Simulation execution logs for post-synth and post-impl runs
├── reports/                    # Utilization and timing summary reports
│   ├── util_synth.rpt          # Post-synthesis utilization report
│   ├── timing_synth.rpt        # Post-synthesis timing report
│   ├── util_impl.rpt           # Post-implementation utilization report
│   ├── timing_impl.rpt         # Post-implementation timing report
│   └── route_status.rpt        # Detailed routing status (100% fully routed)
├── run_full_verification.sh    # End-to-end master regression runner (Synth -> Impl -> 18 sims)
├── run_post_synth_sim.sh       # Post-synthesis functional simulation suite (9 testbenches)
├── run_post_impl_sim.sh        # Post-implementation functional simulation suite (9 testbenches)
├── run_synth_impl.tcl          # Vivado batch script for synthesis, place, phys_opt, and route
├── tb/                         # Self-checking SystemVerilog testbenches (glbl/GSR-hardened)
│   ├── tb_keygen_512.sv        # KeyGen Category 1
│   ├── tb_keygen_768.sv        # KeyGen Category 3
│   ├── tb_keygen_1024.sv       # KeyGen Category 5
│   ├── tb_encap_512.sv         # Encapsulation Category 1
│   ├── tb_encap_768.sv         # Encapsulation Category 3
│   ├── tb_encap_1024.sv        # Encapsulation Category 5
│   ├── tb_decap_512.sv         # Decapsulation Category 1
│   ├── tb_decap_768.sv         # Decapsulation Category 3
│   └── tb_decap_1024.sv        # Decapsulation Category 5
└── vectors/                    # NIST FIPS 203 KAT reference hex vectors
```

---

## ⚡ Key Technical Details: Gate-Level Simulation Considerations

### 1. Xilinx `glbl.GSR` Power-On Reset Handling
When simulating gate-level structural netlists compiled against AMD/Xilinx UNISIMS (`unisims_ver`), all hardware primitives (`FDRE`, `FDSE`, `RAM64M8`, `DSP48E2`, etc.) are coupled to the global reset signal `glbl.GSR`.
* In `glbl.v`, `GSR` is held asserted for $\text{ROC\_WIDTH} = 100\,000\text{ ps} = 100\text{ ns}$.
* While `GSR` is active, all flip-flops are held in their power-on reset state and ignore clock edges.
* All testbenches in this suite include a mandatory `#150;` ($150\text{ ns}$) delay before releasing active-low reset `rst_n` and pulsing `start = 1` to guarantee proper circuit initialization.

### 2. Post-Route Gate Delay & Readout Margins
In gate-level netlists, clock-to-Q and combinational LUT paths introduce physical propagation delays ($\sim 200\text{--}400\text{ ps}$). Testbenches sample synchronous read ports (`mem_rd_data`) with a mid-cycle delay (`#1.0;` ns at 450 MHz / 2.222 ns clock period) to ensure robust setup and hold margins.

---

## 🚀 How to Run

### Run Post-Synthesis Verification (9 testbenches)
```bash
bash post_synth_impl_verification/run_post_synth_sim.sh
```

### Run Post-Implementation Verification (9 testbenches)
```bash
bash post_synth_impl_verification/run_post_impl_sim.sh
```

### Run Full End-to-End Flow (Synthesis + Implementation + All 18 Simulations)
```bash
bash post_synth_impl_verification/run_full_verification.sh
```
