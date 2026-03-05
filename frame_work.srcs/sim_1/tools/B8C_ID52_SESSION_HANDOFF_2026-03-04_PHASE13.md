# B8C ID52 会话交接文档（Phase13，2026-03-04）

## 1. 一句话状态
ID52 主线已稳定通过；parser 去泡后端到端从约 1.227x 提升到约 1.300x，当前性能已接近本架构理论上限，后续瓶颈主要在计算尾段与体系级解耦而非 parser 本身。

## 2. 本会话完成内容

### 2.1 RTL 修改
1. `frame_work.srcs/sources_1/new/id_unpack_parser.v`
- 增加无气泡 block 切换：在块尾拍直接切到已就绪 bank。

2. `frame_work.srcs/sources_1/new/meta_parser.v`
- 同步实现无气泡 block 切换。
- 直接解决了此前 `meta_empty/pair_wait` 的周期性积累。

### 2.2 保持已有能力（未回退）
1. `frame_work.srcs/sources_1/new/b8c_decoder_id52.v`
- 支持 `DECOUPLE_ID_META`、`ID_Q_DEPTH`、`META_Q_DEPTH`
- `DEC_STATS` 统计保留

2. `frame_work.srcs/sources_1/new/b8c_top.v`
- 参数透传保留

3. `frame_work.srcs/sim_1/new/tb_b8c_top_ram.sv`
- `READY_STATS` 与解耦参数透传保留

4. `frame_work.srcs/sim_1/tools/compare_mode_timing.py`
- 继续支持参数化对比与 `DEC_STATS/READY_STATS` 解析

## 3. 核心实测结果（本会话）

### 3.1 主对比（去泡后）
命令：
```powershell
C:\IC\.venv\Scripts\python.exe frame_work.srcs/sim_1/tools/compare_mode_timing.py --prefix bubblefix_d8 --decouple-id-meta 1 --id-q-depth 8 --meta-q-depth 8
```

结果摘要：
- MODE0 PASS，MODE1 PASS
- `compute_beats`: `16674 -> 5558`（3.000x）
- `feed_ns`: `166750 -> 122890`（1.357x）
- `total_compute_to_finish_ns`: `172230 -> 132450`（1.300x）
- MODE1: `ready_low_ratio=0.548`
- MODE1: `dec_pair_wait_cycles=5`

### 3.2 与去泡前历史对比（同配置）
- 去泡前：`total_compute_to_finish_ns ≈ 140380ns`, `pair_wait ≈ 798`
- 去泡后：`total_compute_to_finish_ns = 132450ns`, `pair_wait = 5`
- 结论：本会话优化有效，主要收益来自消除 parser 块间固定气泡。

### 3.3 参数扫描
命令：
```powershell
C:\IC\.venv\Scripts\python.exe frame_work.srcs/sim_1/tools/compare_mode_timing.py --prefix bubblefix_lock --decouple-id-meta 0 --id-q-depth 8 --meta-q-depth 8
C:\IC\.venv\Scripts\python.exe frame_work.srcs/sim_1/tools/compare_mode_timing.py --prefix bubblefix_d4   --decouple-id-meta 1 --id-q-depth 4  --meta-q-depth 4
C:\IC\.venv\Scripts\python.exe frame_work.srcs/sim_1/tools/compare_mode_timing.py --prefix bubblefix_d16  --decouple-id-meta 1 --id-q-depth 16 --meta-q-depth 16
```

结论：
- `DECOUPLE_ID_META=0/1` 性能近乎一致。
- `ID_Q_DEPTH/META_Q_DEPTH` 在 `4~16` 区间几乎不影响总时长。
- 当前阶段队列参数不是决定性瓶颈。

## 4. 当前瓶颈判断
1. 结构性上限
- 现架构下 ID52 主要减少输入传输 beats，不减少最终有效计算 token（约 12704）。
- 端到端理论上限约 `16674/12704 ≈ 1.313x`。
- 现状 `1.300x` 已接近该上限。

2. 尾段延迟
- `drain_ns` 在 MODE1 仍约 `4.33us`，高于 legacy。
- 后续优先查 `b8c_top` 中 `S_COMPUTE -> S_STORE_Y` 的清空/切换策略。

3. 覆盖与实现缺口
- 回归仍以 `hpcg_16-1` 为主。
- 尚未做综合后资源/Fmax/时序闭合验证。

## 5. 建议下一会话执行顺序
1. 固化默认参数（建议）
- 默认 `DECOUPLE_ID_META=0`（更简洁且性能基本无损）。

2. 攻击尾段开销
- 在 `b8c_top.v` 定位 `drain_ns` 来源，尝试缩短 compute 尾部到 writeback 起始的空转周期。

3. 做实现态验证
- 跑综合与时序，确认 parser 改动在硬件实现中的资源与时钟影响。

4. 扩大数据集回归
- 增加至少 1~2 组矩阵案例，确认收益与正确性可泛化。

## 6. 关键文件清单
- `frame_work.srcs/sources_1/new/id_unpack_parser.v`
- `frame_work.srcs/sources_1/new/meta_parser.v`
- `frame_work.srcs/sources_1/new/b8c_decoder_id52.v`
- `frame_work.srcs/sources_1/new/b8c_top.v`
- `frame_work.srcs/sim_1/new/tb_b8c_top_ram.sv`
- `frame_work.srcs/sim_1/tools/compare_mode_timing.py`
- `frame_work.srcs/sim_1/tools/B8C_ID52_CURRENT_VERSION_CHANGE_REPORT.md`

## 7. 快速复现命令
```powershell
# 主结果（推荐）
C:\IC\.venv\Scripts\python.exe frame_work.srcs/sim_1/tools/compare_mode_timing.py --prefix bubblefix_d8 --decouple-id-meta 1 --id-q-depth 8 --meta-q-depth 8

# 仅复用日志汇总
C:\IC\.venv\Scripts\python.exe frame_work.srcs/sim_1/tools/compare_mode_timing.py --prefix bubblefix_d8 --decouple-id-meta 1 --id-q-depth 8 --meta-q-depth 8 --reuse-logs
```
