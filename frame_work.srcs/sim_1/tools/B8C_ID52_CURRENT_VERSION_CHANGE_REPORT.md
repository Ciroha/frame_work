# B8C ID52 当前版本修改说明（2026-03-04）

## 1. 文档目的
本文件说明当前工作区版本相对上一个交接阶段的新增修改、实测结果、以及仍存在的不足。

## 2. 本轮新增修改（核心）

### 2.1 去除 parser 块间 1-cycle 气泡
修改文件：
- `frame_work.srcs/sources_1/new/id_unpack_parser.v`
- `frame_work.srcs/sources_1/new/meta_parser.v`

修改点：
- 在 `emit_ptr == EMIT_COUNT-1` 的收尾拍，若对侧 bank 已 ready，直接切换 `emit_bank` 并保持 `emit_active=1`。
- 不再先拉低 `emit_active` 再下一拍重启，消除每 16 个 token 一次的固定气泡。
- 该改动不改变模块接口，不改变数据格式，不改变外部时序约束。

直接收益：
- `meta_parser` 侧“每块必停 1 拍”问题被消除，显著降低 ID/meta 配对等待。

### 2.2 既有解耦能力保留（本轮未回退）
关键文件（之前已完成，本轮继续保持）：
- `frame_work.srcs/sources_1/new/b8c_decoder_id52.v`
  - `DECOUPLE_ID_META` 参数化开关
  - ID/META 队列深度参数：`ID_Q_DEPTH`、`META_Q_DEPTH`
  - `DEC_STATS` 统计输出
- `frame_work.srcs/sources_1/new/b8c_top.v`
  - 解耦参数透传
- `frame_work.srcs/sim_1/new/tb_b8c_top_ram.sv`
  - 解耦参数透传
  - `READY_STATS` 输出
- `frame_work.srcs/sim_1/tools/compare_mode_timing.py`
  - 支持传入/对比解耦与队列深度参数
  - 解析 `READY_STATS` + `DEC_STATS`

## 3. 回归验证结果

### 3.1 主验证点（去泡后）
命令：
```powershell
C:\IC\.venv\Scripts\python.exe frame_work.srcs/sim_1/tools/compare_mode_timing.py --prefix bubblefix_d8 --decouple-id-meta 1 --id-q-depth 8 --meta-q-depth 8
```

结果（MODE0=legacy, MODE1=ID52）：
- `pass`: `True / True`
- `compute_beats`: `16674 -> 5558`（3.000x）
- `feed_ns`: `166750 -> 122890`（1.357x）
- `total_compute_to_finish_ns`: `172230 -> 132450`（1.300x）
- MODE1 `ready_low_ratio`: `0.548`
- MODE1 `dec_pair_wait_cycles`: `5`
- MODE1 `dec_meta_empty_cycles`: `11`

### 3.2 与去泡前结果对比（同为 decouple=1, q=8/8）
去泡前（历史实测）：
- `feed_ns = 130550`
- `total_compute_to_finish_ns = 140380`
- `dec_pair_wait_cycles = 798`

去泡后（本轮）：
- `feed_ns = 122890`（进一步缩短约 7660 ns）
- `total_compute_to_finish_ns = 132450`（进一步缩短约 7930 ns）
- `dec_pair_wait_cycles = 5`（基本消除）

### 3.3 解耦开关与队列深度扫描
命令：
```powershell
# lockstep
C:\IC\.venv\Scripts\python.exe frame_work.srcs/sim_1/tools/compare_mode_timing.py --prefix bubblefix_lock --decouple-id-meta 0 --id-q-depth 8 --meta-q-depth 8

# decouple + depth sweep
C:\IC\.venv\Scripts\python.exe frame_work.srcs/sim_1/tools/compare_mode_timing.py --prefix bubblefix_d4  --decouple-id-meta 1 --id-q-depth 4  --meta-q-depth 4
C:\IC\.venv\Scripts\python.exe frame_work.srcs/sim_1/tools/compare_mode_timing.py --prefix bubblefix_d8  --decouple-id-meta 1 --id-q-depth 8  --meta-q-depth 8
C:\IC\.venv\Scripts\python.exe frame_work.srcs/sim_1/tools/compare_mode_timing.py --prefix bubblefix_d16 --decouple-id-meta 1 --id-q-depth 16 --meta-q-depth 16
```

结论：
- `decouple=0` 与 `decouple=1` 性能几乎一致（`132440ns` vs `132450ns`）。
- `q=4/4, 8/8, 16/16` 性能几乎一致，说明当前阶段队列深度已非主瓶颈。
- `id_full_cycles` 在小深度可很高，但不影响总吞吐（说明 ID 侧有富余）。

## 4. 当前版本的优势体现（2:5）
- 编码层面：`compute_beats` 从 `16674` 降到 `5558`，压缩比稳定 `3.000x`。
- 系统层面：在 parser 去泡后，`total_compute_to_finish_ns` 已达到 `1.300x` 提升，显著优于此前 `~1.227x`。
- 配对等待：`dec_pair_wait_cycles` 从约 `798` 降至 `5`，说明“前端配对卡顿”问题已基本解决。

## 5. 仍存在的不足与瓶颈

1. 端到端加速上限受计算主链限制（结构性瓶颈）
- 当前计算链路本质仍以“每 token 1 cycle”推进，ID52 只减少输入 beats，不减少最终有效计算 token 数（约 12704）。
- 因此在当前架构下，端到端速度提升不可能接近 3x，理论上限约在 `16674/12704 ≈ 1.313x`。
- 目前实测 `1.300x` 已接近该上限。

2. `ready_low_ratio` 仍高（约 0.548）
- 这已不主要是 parser 气泡导致，而是输入流与下游消费速率耦合、FIFO 容量有限的自然结果。
- 要再降，需要体系级改造（更深缓冲/跨阶段解耦），而非仅微调 parser。

3. `drain_ns` 仍明显高于 legacy
- MODE1 `drain_ns ≈ 4.33us`，说明“all_data_sent -> writeback_start”阶段仍有尾部开销。
- 可继续检查 `b8c_top` 的 `S_COMPUTE -> S_STORE_Y` 转移条件与 drain 计数策略。

4. 验证覆盖与实现收敛不足
- 当前主要在 `hpcg_16-1` 场景验证。
- 尚未给出综合后资源、Fmax、时序收敛结论。

## 6. 建议下一步
1. 若优先稳健：默认保持 `DECOUPLE_ID_META=0`（性能已接近，逻辑更简单）。
2. 若优先极限性能：转向 `b8c_top` 计算尾段（drain/store）与跨阶段缓冲策略，而非继续堆 parser/queue 参数。
3. 进入实现阶段验证：补综合与时序，确认当前改动在硬件实现下无副作用。
