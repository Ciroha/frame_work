# B8C ID52 会话交接文档（Phase12，2026-03-04）

## 1. 当前状态（一句话）
ID52 功能正确可回归通过，parser 吞吐已优化并增加了背压统计；但 2:5 性能优势仍未完全释放，核心卡点仍在前端握手/反压与 ID/meta 锁步。

## 2. 本会话已完成事项

### 2.1 代码修改
- `frame_work.srcs/sources_1/new/id_unpack_parser.v`
  - 双缓冲 ping-pong
  - 连续读请求
  - fill/emit 重叠
- `frame_work.srcs/sources_1/new/meta_parser.v`
  - 双缓冲 ping-pong
  - 连续读请求
  - fill/emit 重叠
- `frame_work.srcs/sim_1/new/tb_b8c_top_ram.sv`
  - 新增 `READY_STATS` 统计输出
- `frame_work.srcs/sim_1/tools/compare_mode_timing.py`
  - 解析 `READY_STATS`
  - 报表新增 ready 相关列
- `frame_work.srcs/sources_1/new/b8c_decoder_id52.v`
  - 当前保持锁步稳定版本（`id_valid && meta_valid` + `fp_vec_d1`）

### 2.2 尝试过但未保留
- 尝试了 ID/meta 解耦队列版本，曾出现：
  - `AUTO-CHECK FAILED with 967 mismatches`
- 已回退到正确版本，保证当前主线可用。

## 3. 已验证结果

执行：
```powershell
C:\IC\.venv\Scripts\python.exe frame_work.srcs/sim_1/tools/compare_mode_timing.py --prefix phase12_fix1
```

结果：
- MODE0：PASS
- MODE1：PASS
- `compute_beats`: `16674 -> 5558`（3.000x）
- `feed_ns`: `166750 -> 130550`（1.277x）
- `total_compute_to_finish_ns`: `172230 -> 140370`（1.227x）
- MODE1 `ready_low_ratio = 0.574`

日志：
- `frame_work.sim/sim_1/behav/xsim/simulate_phase12_fix1_m0.log`
- `frame_work.sim/sim_1/behav/xsim/simulate_phase12_fix1_m1.log`

## 4. 关键结论

1. parser 内部气泡已明显改善，但系统仍被前端背压限制。  
2. `ready_low_ratio` 高达 `57.4%`，说明输入半数以上周期在等待。  
3. 若要继续逼近 2:5 理论优势，ID/meta 解耦是下一关键步，但必须以可验证、可回退方式推进。

## 5. 下一会话建议执行顺序

1. 在 `b8c_decoder_id52.v` 做“可开关”的解耦实现  
   - 新参数示例：`DECOUPLE_ID_META = 0/1`
   - 默认先 `0`（锁步）保证不回归
2. 在 `DECOUPLE_ID_META=1` 下引入小队列并保持严格配对语义  
   - 注意值/元数据对齐，不破坏 `fp_vec_d1` 相关时序
3. 增加内部统计  
   - ID 队列空/满周期
   - META 队列空/满周期
   - 等待配对周期
4. 再跑 A/B  
   - 目标先看 `ready_low_ratio` 显著下降
   - 再看 `feed_ns` 是否继续逼近 2x~3x 区间

## 6. 快速复现命令

```powershell
# 1) 可选：重生成 ID52 输入
C:\IC\.venv\Scripts\python.exe frame_work.srcs/sim_1/tools/convert_to_b8c_hex.py `
  --mtx C:\IC\SpMV\hpcg_16-1.mtx `
  --out-dir C:\IC\FPGA\frame_work\frame_work.srcs\sim_1\data\hpcg_16-1 `
  --vector-depth 512 `
  --x-file C:\IC\FPGA\frame_work\frame_work.srcs\sim_1\data\hpcg_16-1\x_all_ones_4096.txt

# 2) 跑最新 A/B
C:\IC\.venv\Scripts\python.exe frame_work.srcs/sim_1/tools/compare_mode_timing.py --prefix phase12_fix1

# 3) 仅重解析已有日志
C:\IC\.venv\Scripts\python.exe frame_work.srcs/sim_1/tools/compare_mode_timing.py --prefix phase12_fix1 --reuse-logs
```

## 7. 相关文档
- 当前版本修改说明：
  - `frame_work.srcs/sim_1/tools/B8C_ID52_CURRENT_VERSION_CHANGE_REPORT.md`
- 上一版历史交接：
  - `frame_work.srcs/sim_1/tools/B8C_ID52_SESSION_SUMMARY.md`

