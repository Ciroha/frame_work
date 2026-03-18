# DDR4 Adapter Interface Plan

## Goal
- Move from the current behavioral stream-fed memory assumption toward a real DDR4-backed architecture.
- Keep `b8c_top` largely stream-oriented internally in v1.
- Introduce an adapter layer between AXI4-MM DDR4 access and the internal stream or buffer consumers.

## Architecture Boundary
### External side
- Xilinx DDR4 or MIG generated AXI4 memory-mapped interface.
- Read path is the immediate priority.
- Writeback path for Y is required, but can be phase 2 if read-side integration is the main blocker.

### Internal side
- Matrix stream feed toward decoder.
- X preload buffer fill.
- Y writeback drain.

## Proposed Blocks
### 1. `ddr_read_req_scheduler`
- Accepts logical fetch requests for:
  - matrix payload stream
  - X vector preload
- Merges adjacent requests into bursts where possible.
- Tracks outstanding transactions.

### 2. `ddr_read_reorder_buffer`
- Reorders AXI read responses into internal consumer order.
- Feeds either:
  - a direct AXIS-like matrix stream
  - a local vector fill path for X

### 3. `ddr_writeback_adapter`
- Converts Y result beats into AXI4 write bursts.
- Handles padding on the final beat.

### 4. `stream_to_mem_profile_hooks`
- Exposes request count, burst count, average burst length, and effective payload efficiency for the performance model.

## Interface Recommendation
### Internal fetch request
```verilog
input  wire         req_valid;
output wire         req_ready;
input  wire [31:0]  req_addr_bytes;
input  wire [15:0]  req_len_bytes;
input  wire [1:0]   req_class;   // matrix / xload / other
```

### Internal stream response
```verilog
output wire         rsp_valid;
input  wire         rsp_ready;
output wire [511:0] rsp_data;
output wire         rsp_last;
output wire [1:0]   rsp_class;
```

## Planning Assumptions
- AXI data width stays 512 bits to stay aligned with the existing internal stream width.
- Matrix payload and X preload can share the same physical DDR4 channel in v1.
- The adapter should tolerate longer and less predictable latency than the current HBM simulation model.
- Burst efficiency must be modeled explicitly because DDR4 bottlenecks are strongly burst-length dependent.

## What Not To Do In V1
- Do not push AXI4-MM all the way into `b8c_top`.
- Do not entangle MIG timing details with decoder logic.
- Do not assume fully random single-beat access is acceptable. The adapter must prefer burst-friendly scheduling.

## Verification Targets
- Sequential burst reads.
- Burst split at boundary.
- Read response backpressure.
- Mixed matrix or X fetch arbitration.
- Y writeback burst generation.
- End-to-end no-deadlock under long response latency.

## Integration Order
1. Keep the current stream-fed simulation path as the functional reference.
2. Add adapter-side profiling counters for burst length, payload bytes, idle cycles, and outstanding transactions so `eta_ext` can be calibrated from real runs.
3. Build the read scheduler and reorder buffer first, because matrix and X fetch bandwidth determine whether the multiplier array can be kept busy.
4. Add Y writeback after the read side is stable, since write bandwidth is important but not the first blocker for end-to-end bring-up.
5. Only then bind the adapter to a concrete MIG configuration and feed the measured DDR4 behavior back into `spmv_perf_model.py`.
