set_param general.maxThreads 4
create_project -in_memory -part xcku035-ffva1156-3-e

read_verilog -sv mlkem_hpka_accelerator/hash_sampler/rtl/keccak_f1600.sv
read_verilog -sv mlkem_hpka_accelerator/hash_sampler/rtl/mlkem_hash_sampler.sv
read_verilog -sv mlkem_hpka_accelerator/ntt_intt/rtl/mlkem_butterfly.sv
read_verilog -sv mlkem_hpka_accelerator/ntt_intt/rtl/mlkem_ntt_intt.sv
read_verilog -sv mlkem_hpka_accelerator/mul_stream/rtl/mlkem_mul_stream.sv
read_verilog -sv mlkem_hpka_accelerator/field_add/rtl/field_add.sv
read_verilog -sv mlkem_hpka_accelerator/field_sub/rtl/field_sub.sv
read_verilog -sv mlkem_hpka_accelerator/new_compress_decompress/rtl/mlkem_poly_compress.sv
read_verilog -sv mlkem_hpka_accelerator/new_compress_decompress/rtl/mlkem_poly_decompress.sv
read_verilog -sv mlkem_hpka_accelerator/new_poly_encode_decode_1/rtl/poly_encode.sv
read_verilog -sv mlkem_hpka_accelerator/new_poly_encode_decode_1/rtl/poly_decode.sv
read_verilog -sv mlkem_hpka_accelerator/accel_core/rtl/mlkem_keygen_top.sv

set_property include_dirs {mlkem_hpka_accelerator/ntt_intt/rtl mlkem_hpka_accelerator/accel_core/rtl} [current_fileset]

read_xdc build/constraints.xdc

synth_design -top mlkem_keygen_top -part xcku035-ffva1156-3-e -mode out_of_context -max_bram 0 -max_dsp 8 -directive PerformanceOptimized -retiming -no_lc -resource_sharing off

report_utilization -file build/run_speedgrade3/util_synth.rpt
report_timing_summary -max_paths 20 -file build/run_speedgrade3/timing_synth.rpt

opt_design -directive ExploreWithRemap

place_design -directive Explore

phys_opt_design -directive AggressiveExplore
phys_opt_design -directive AlternateReplication

route_design -directive AlternateCLBRouting

phys_opt_design -directive AggressiveExplore
route_design -tns_cleanup

report_utilization -file build/run_speedgrade3/util_impl.rpt
report_timing_summary -max_paths 20 -file build/run_speedgrade3/timing_impl.rpt
report_route_status -file build/run_speedgrade3/route_status.rpt
