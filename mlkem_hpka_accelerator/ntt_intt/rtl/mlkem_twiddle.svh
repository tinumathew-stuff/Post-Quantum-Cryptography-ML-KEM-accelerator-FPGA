//==============================================================================
// File: mlkem_twiddle.svh
// Project: ML-KEM (CRYSTALS-Kyber) High-Performance Hardware Accelerator
// Component: 12-bit Twiddle Factor ROM & Lookup Function (NTT / INTT)
//
// Description:
//   Precomputed lookup table (ROM) and accessor function providing 12-bit
//   powers of the primitive root of unity (twiddle factors) for the Number
//   Theoretic Transform (NTT) and Inverse NTT (INTT) in ML-KEM (FIPS 203).
//
// Mathematical & Algorithmic Background:
//   1. Ring and Field Parameters:
//      - ML-KEM operates over the cyclotomic quotient ring:
//          R_q = Z_q[X] / (X^256 + 1)
//        where the prime modulus is:
//          q = 3329 = 13 * 2^8 + 1 = 13 * 256 + 1
//      - Because 256 divides (q - 1) = 3328, the finite field GF(q) contains
//        all 256th roots of unity.
//      - The canonical primitive 256th root of unity chosen in FIPS 203 is:
//          zeta = 17 (mod 3329)
//        Satisfying:
//          17^256 = 1 (mod 3329)
//          17^128 = -1 = 3328 (mod 3329)
//
//   2. Forward NTT Twiddle Factors (Indices 0 .. 127, inverse = 0):
//      - In the 7-layer Cooley-Tukey (CT) Decimation-in-Time (DIT) NTT,
//        the polynomial X^256 + 1 factors into 128 quadratic polynomials:
//          X^256 + 1 = PROD_{i=0..127} (X^2 - zeta^(2 * BitRev_7(i) + 1)) (mod q)
//      - Twiddle factors are accessed in bit-reversed sequence:
//          TWIDDLE_ROM[i] = zeta^(BitRev_7(i)) mod q, for i in [0 .. 127]
//      - Selected boundary values:
//          i = 0   : zeta^0   = 1
//          i = 1   : zeta^64  = 17^64  = 1729 (mod 3329)
//          i = 2   : zeta^32  = 17^32  = 2580 (mod 3329)
//          ...
//          i = 127 : zeta^127 = 17^127 = 2154 (mod 3329)
//
//   3. Inverse INTT Twiddle Factors (Indices 128 .. 255, inverse = 1):
//      - In the 7-layer Gentleman-Sande (GS) Decimation-in-Frequency (DIF) INTT,
//        the butterflies compute the subtraction (a - b) followed by
//        modular multiplication by the negated twiddle factor:
//          -zeta^(-BitRev_7(i)) (mod q)  =  (q - zeta^(BitRev_7(i))) (mod q)
//      - Therefore, each inverse entry is algebraically related to the forward entry by:
//          TWIDDLE_ROM[128 + i] = (q - TWIDDLE_ROM[i]) mod q
//      - Selected boundary values:
//          i = 0   : 3329 - 1    = 3328 (mod 3329)
//          i = 1   : 3329 - 1729 = 1600 (mod 3329)
//          i = 2   : 3329 - 2580 = 749  (mod 3329)
//          ...
//          i = 127 : 3329 - 2154 = 1175 (mod 3329)
//
// Hardware Architecture & Memory Mapping:
//   - Total Storage: 256 entries * 12 bits = 3,072 bits.
//   - Target Technology: Synthesizes directly into distributed LUT-ROM
//     (LUT6 primitives acting as ROM64x1) or a small fraction of a 36Kb UltraScale+
//     Block RAM (RAMB36E2).
//   - Addressing Scheme:
//       Address = {inverse, index[6:0]} (8 bits total)
//       - Address[7]   (MSB) : 'inverse' flag (0: Forward NTT, 1: Inverse INTT)
//       - Address[6:0] (LSBs): 7-bit butterfly twiddle leaf index (0 to 127)
//   - Eliminates 128 dynamic 64-bit barrel shifters and real-time modular
//     exponentiation pipelines, enabling deterministic single-cycle access
//     and zero-DSP timing closure at 450 MHz.
//==============================================================================

`ifndef MLKEM_TWIDDLE_SVH
`define MLKEM_TWIDDLE_SVH

//------------------------------------------------------------------------------
// Constant Twiddle Factor ROM (256 x 12-bit)
// Contains bit-reversed forward NTT zetas and negated inverse INTT zetas.
//------------------------------------------------------------------------------
localparam logic [11:0] TWIDDLE_ROM [0:255] = '{
    //--------------------------------------------------------------------------
    // Forward NTT Twiddles (inverse = 0, index = 0..127)
    // zeta^(BitRev_7(index)) mod 3329
    //--------------------------------------------------------------------------
    12'd1, 12'd1729, 12'd2580, 12'd3289, 12'd2642, 12'd630, 12'd1897, 12'd848,
    12'd1062, 12'd1919, 12'd193, 12'd797, 12'd2786, 12'd3260, 12'd569, 12'd1746,
    12'd296, 12'd2447, 12'd1339, 12'd1476, 12'd3046, 12'd56, 12'd2240, 12'd1333,
    12'd1426, 12'd2094, 12'd535, 12'd2882, 12'd2393, 12'd2879, 12'd1974, 12'd821,
    12'd289, 12'd331, 12'd3253, 12'd1756, 12'd1197, 12'd2304, 12'd2277, 12'd2055,
    12'd650, 12'd1977, 12'd2513, 12'd632, 12'd2865, 12'd33, 12'd1320, 12'd1915,
    12'd2319, 12'd1435, 12'd807, 12'd452, 12'd1438, 12'd2868, 12'd1534, 12'd2402,
    12'd2647, 12'd2617, 12'd1481, 12'd648, 12'd2474, 12'd3110, 12'd1227, 12'd910,
    12'd17, 12'd2761, 12'd583, 12'd2649, 12'd1637, 12'd723, 12'd2288, 12'd1100,
    12'd1409, 12'd2662, 12'd3281, 12'd233, 12'd756, 12'd2156, 12'd3015, 12'd3050,
    12'd1703, 12'd1651, 12'd2789, 12'd1789, 12'd1847, 12'd952, 12'd1461, 12'd2687,
    12'd939, 12'd2308, 12'd2437, 12'd2388, 12'd733, 12'd2337, 12'd268, 12'd641,
    12'd1584, 12'd2298, 12'd2037, 12'd3220, 12'd375, 12'd2549, 12'd2090, 12'd1645,
    12'd1063, 12'd319, 12'd2773, 12'd757, 12'd2099, 12'd561, 12'd2466, 12'd2594,
    12'd2804, 12'd1092, 12'd403, 12'd1026, 12'd1143, 12'd2150, 12'd2775, 12'd886,
    12'd1722, 12'd1212, 12'd1874, 12'd1029, 12'd2110, 12'd2935, 12'd885, 12'd2154,

    //--------------------------------------------------------------------------
    // Inverse INTT Twiddles (inverse = 1, index = 0..127)
    // (3329 - zeta^(BitRev_7(index))) mod 3329
    //--------------------------------------------------------------------------
    12'd3328, 12'd1600, 12'd749, 12'd40, 12'd687, 12'd2699, 12'd1432, 12'd2481,
    12'd2267, 12'd1410, 12'd3136, 12'd2532, 12'd543, 12'd69, 12'd2760, 12'd1583,
    12'd3033, 12'd882, 12'd1990, 12'd1853, 12'd283, 12'd3273, 12'd1089, 12'd1996,
    12'd1903, 12'd1235, 12'd2794, 12'd447, 12'd936, 12'd450, 12'd1355, 12'd2508,
    12'd3040, 12'd2998, 12'd76, 12'd1573, 12'd2132, 12'd1025, 12'd1052, 12'd1274,
    12'd2679, 12'd1352, 12'd816, 12'd2697, 12'd464, 12'd3296, 12'd2009, 12'd1414,
    12'd1010, 12'd1894, 12'd2522, 12'd2877, 12'd1891, 12'd461, 12'd1795, 12'd927,
    12'd682, 12'd712, 12'd1848, 12'd2681, 12'd855, 12'd219, 12'd2102, 12'd2419,
    12'd3312, 12'd568, 12'd2746, 12'd680, 12'd1692, 12'd2606, 12'd1041, 12'd2229,
    12'd1920, 12'd667, 12'd48, 12'd3096, 12'd2573, 12'd1173, 12'd314, 12'd279,
    12'd1626, 12'd1678, 12'd540, 12'd1540, 12'd1482, 12'd2377, 12'd1868, 12'd642,
    12'd2390, 12'd1021, 12'd892, 12'd941, 12'd2596, 12'd992, 12'd3061, 12'd2688,
    12'd1745, 12'd1031, 12'd1292, 12'd109, 12'd2954, 12'd780, 12'd1239, 12'd1684,
    12'd2266, 12'd3010, 12'd556, 12'd2572, 12'd1230, 12'd2768, 12'd863, 12'd735,
    12'd525, 12'd2237, 12'd2926, 12'd2303, 12'd2186, 12'd1179, 12'd554, 12'd2443,
    12'd1607, 12'd2117, 12'd1455, 12'd2300, 12'd1219, 12'd394, 12'd2444, 12'd1175
};

//------------------------------------------------------------------------------
// Twiddle Factor Lookup Function: twiddle
//
// Description:
//   Accesses the twiddle factor ROM using a concatenated 8-bit index:
//     - inverse: 1'b0 for Forward NTT (0..127), 1'b1 for Inverse INTT (128..255)
//     - index  : 7-bit leaf index in bit-reversed order (0..127)
//
// Returns:
//   12-bit modular twiddle factor in canonical form [0, 3328].
//------------------------------------------------------------------------------
function automatic logic [11:0] twiddle(input logic inverse, input logic [6:0] index);
    return TWIDDLE_ROM[{inverse, index}];
endfunction

`endif // MLKEM_TWIDDLE_SVH
