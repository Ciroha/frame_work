# IEEE FP64 Multiplier Integration Plan

## Goal
- Replace the current placeholder path in `compute_pipeline` with a real hardware FP64 multiplier.
- Keep the top-level `b8c_top` stream contract unchanged.
- Use a pipelined interface so performance modeling and later lane scaling stay explicit.
- Keep the multiplier implementation decoupled from decoder and `y_acc_banks` so latency, II, and implementation style remain replaceable.

## Recommended Internal Interface
```verilog
input  wire         s_valid;
output wire         s_ready;
input  wire [63:0]  s_a_bits;
input  wire [63:0]  s_b_bits;

output wire         m_valid;
input  wire         m_ready;
output wire [63:0]  m_result_bits;
output wire [4:0]   m_status;
```

Notes:
- `m_status` should at least cover invalid, overflow, underflow, and inexact.
- If fixed-backpressure is preferred, `s_ready` can be tied high and `m_ready` assumed high in v1, but the signal should still exist in the interface.
- Optional debug outputs can be exposed as separate counters or taps, for example `m_overflow` and `m_underflow`, without changing the main datapath contract.
- Rounding mode should stay out of the streaming payload. If configurability is needed, add a sideband control such as `cfg_rounding_mode` rather than per-beat status inputs.

## Pipeline Split
### Stage 0: unpack
- Extract sign, exponent, fraction.
- Detect zero, subnormal, infinity, NaN.
- Add hidden bit for normalized numbers.

### Stage 1: special-case classify
- Resolve NaN propagation.
- Resolve zero * infinity invalid case.
- Resolve sign for standard finite cases.

### Stage 2: mantissa multiply
- Multiply 53-bit mantissas to produce a 106-bit raw product.
- Map to DSP-friendly decomposition if handwritten RTL is used.
- This stage is the main DSP cost driver and should be written to make DSP48E2 mapping explicit.

### Stage 3: exponent path
- Add exponents and subtract bias.
- Track carry-out or overflow headroom for normalization.
- This path should execute in parallel with the mantissa multiply rather than waiting behind it.

### Stage 4: normalize
- Normalize the 106-bit product.
- Adjust exponent based on the MSB position.
- The leading-zero or leading-one detection strategy must be chosen explicitly because it is a likely timing bottleneck.
- If timing is weak, split normalization into a detect stage and a shift-select stage rather than forcing it into one cycle.

### Stage 5: round
- Implement round-to-nearest-even first.
- Keep guard, round, and sticky bits explicit.
- Rounding may generate a carry that forces a second normalization step and exponent increment. That path must be accounted for in the stage budget.

### Stage 6: repack
- Reassemble sign, exponent, and fraction.
- Saturate to Inf on overflow.
- Generate zero, subnormal, or underflow result when required.

## Pipeline Notes
- A nominal six to seven stage pipeline is still the recommended baseline, but Stage 2 and Stage 3 should be treated as parallel subpaths rather than strictly serialized work.
- Target the first handwritten implementation at `250 MHz`. If the 53x53 path or normalization path does not close timing, add one more register stage before forcing broad architectural changes.
- Keep latency as a documented constant or a parameter so `compute_pipeline` can align valid timing without embedding floating-point details.

## Integration Strategy
- `compute_pipeline` should stop owning floating-point math directly.
- Instead, it should become a lane wrapper that:
  - fans out lane operands
  - instantiates one FP64 multiplier per lane
  - aligns valid propagation with downstream `y_acc_banks`
- Do not couple multiplier latency to decoder logic. Latency should be a parameter or a documented constant.
- The existing `b8c_top` control path already assumes a shorter compute delay, so integration must include an explicit retiming pass for valid, mask, and destination metadata.

## Verification Targets
- Finite normal x finite normal.
- Zero, subnormal, Inf, and NaN inputs.
- Sign combinations.
- Exponent overflow and underflow.
- Rounding boundary cases.
- Continuous full-throughput input stream with no bubbles.
- Randomized `m_ready` backpressure to confirm no result loss or lane skew.
- End-to-end alignment check against `y_acc_banks` write timing.
- Assertion coverage for special-case priority and rounding carry paths.
- Resource and power snapshots once a single-lane result and a 16-lane estimate are available.

## Recommended Implementation Order
1. Build a single-lane module with explicit pipeline registers and a fixed target latency.
2. Match it against a software or simulation reference and add assertions for special cases.
3. Evaluate DSP usage and critical paths before scaling out lanes.
4. Add status flags and optional debug counters for overflow, underflow, invalid, and inexact events.
5. Replicate per lane, reconnect `compute_pipeline`, and check timing closure at the target lane count.
6. Re-run the performance model with actual multiplier latency, II, and measured clock target.

## Key Risks
- DSP usage is expected to dominate cost. A handwritten FP64 mantissa path will likely consume about 6 to 8 DSP48E2 blocks per lane, so 16 lanes implies roughly 96 to 128 DSPs before support logic.
- The most likely timing bottlenecks are the DSP cascade path, normalization detection or shift selection, and rounding-induced renormalization.
- Integration risk is not limited to the multiplier itself. Valid timing, lane metadata, and downstream accumulation alignment must be rechecked after latency increases.
