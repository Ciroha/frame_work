# B8C ID52 当前版本修改说明（2026-03-04）

## 1. 文档目的
本文件说明“当前工作区版本”相对上次交接后的实际修改内容、验证结果、以及仍存在的不足。

## 2. 本轮新增修改（相对上次交接）

### 2.1 `id_unpack_parser` 吞吐改造
文件：
- `frame_work.srcs/sources_1/new/id_unpack_parser.v`

修改点：
- 从单缓冲串行 `FILL -> EMIT` 改为双缓冲（`cache0/cache1` ping-pong）。
- 引入 `fill_active/emit_active`，允许发射当前块时并行预取下一块。
- 读请求改为连续发起（移除原先“隔拍发读”的节拍损失行为）。
- `parser_valid` 由 `emit_active` 驱动，空闲时输出清零。

效果：
- 去掉了 parser 内部最明显的 fill/emit 硬气泡。

### 2.2 `meta_parser` 吞吐改造
文件：
- `frame_work.srcs/sources_1/new/meta_parser.v`

修改点：
- 与 `id_unpack_parser` 同样改为双缓冲并行填充/发射。
- 连续 FIFO 读请求（保持 FIFO 1-cycle read latency 语义）。
- 输出切片逻辑改为从当前 `emit_bank` 动态选择。

效果：
- 元数据解析不再严格“先读满再发完”，可与下一个 block 的装载重叠。

### 2.3 测试平台新增反压统计
文件：
- `frame_work.srcs/sim_1/new/tb_b8c_top_ram.sv`

修改点：
- 增加 compute 输入阶段 `s_axis_tready` 统计计数：
  - `compute_ready_total_cycles`
  - `compute_ready_high_cycles`
  - `compute_ready_low_cycles`
  - `ready_low_ratio`
- 在日志中新增固定格式输出：
  - `READY_STATS total=... high=... low=... low_ratio=...`
- `feed_burst_array` 增加 `track_ready_stats` 参数，仅对 compute 阶段统计。

效果：
- 可以定量观察前端背压比例，不再只看总时间。

### 2.4 A/B 脚本新增统计解析
文件：
- `frame_work.srcs/sim_1/tools/compare_mode_timing.py`

修改点：
- `SimMetrics` 新增 ready 统计字段。
- 正则解析 `READY_STATS ...`。
- 对比表新增：
  - `ready_total_cycles`
  - `ready_high_cycles`
  - `ready_low_cycles`
  - `ready_low_ratio`

效果：
- 可直接在 MODE0/1 报表中量化 `tready` 低占比差异。

### 2.5 `b8c_decoder_id52` 当前状态说明
文件：
- `frame_work.srcs/sources_1/new/b8c_decoder_id52.v`

当前保留为“已验证正确”的锁步语义：
- `consume_step = compute_req_next && decoder_valid`
- `decoder_valid = id_valid && meta_valid`
- `fp_vec_d1` 对齐寄存继续保留。

说明：
- 本轮曾尝试做 ID/meta 解耦队列，但出现 `AUTO-CHECK FAILED with 967 mismatches`，已回退到正确版本。

## 3. 当前验证结果

执行命令：
```powershell
C:\IC\.venv\Scripts\python.exe frame_work.srcs/sim_1/tools/compare_mode_timing.py --prefix phase12_fix1
```

结果摘要（MODE0=legacy, MODE1=ID52）：
- 功能：`pass=True / True`（均通过）
- `compute_beats`: `16674 -> 5558`（3.000x）
- `feed_ns`: `166750 -> 130550`（1.277x）
- `total_compute_to_finish_ns`: `172230 -> 140370`（1.227x）
- MODE1 `READY_STATS`：
  - `ready_total_cycles=13054`
  - `ready_high_cycles=5558`
  - `ready_low_cycles=7496`
  - `ready_low_ratio=0.574`

日志：
- `frame_work.sim/sim_1/behav/xsim/simulate_phase12_fix1_m0.log`
- `frame_work.sim/sim_1/behav/xsim/simulate_phase12_fix1_m1.log`

## 4. 当前版本仍存在的不足

1. 2:5 优势仍未充分释放  
虽然 `compute_beats` 下降 3x，但 `feed_ns` 仅约 `1.28x`，总时间仅约 `1.23x`。

2. 前端背压仍然很重  
MODE1 的 `ready_low_ratio` 达 `0.574`，说明 compute 输入期超过一半周期在等待。

3. ID/meta 仍是锁步消费  
`decoder_valid = id_valid && meta_valid` 仍会被慢路径拖住；解耦方案尚未稳定落地。

4. `drain_ns` 变长明显  
本次报表中 MODE1 `drain_ns=4600ns`，远高于 MODE0 `260ns`，后段排空仍需定位。

5. 覆盖范围有限  
当前主要在 `hpcg_16-1` 场景验证；尚未对其他矩阵、边界规模做系统回归。

6. 尚未做综合/时序验证  
当前结论基于行为仿真；未给出资源与时序收敛评估。

## 5. 建议下一步

1. 以“可开关参数”方式再次实现 ID/meta 解耦（先保留锁步 fallback）。
2. 在 decoder 内新增更细粒度计数器（ID 队列空/满、META 队列空/满、等待配对周期）。
3. 重点压缩 `ready_low_ratio` 与 `drain_ns`，再做 A/B 验证是否接近 2:5 理论收益。

