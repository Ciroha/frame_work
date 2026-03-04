# B8C ID52 会话交接总结（2026-03-04）

## 1. 当前结论（最重要）
- `2:5 + LUT(ID52)` 功能链路已接通，`hpcg_16-1` 仿真可通过。
- 目前主要瓶颈在**解码前端供数节拍/握手**，不是计算单元本身。
- 传输格式本身没有方向性错误，但当前前端实现没有把 `compute_beats` 降低转化为总时间收益。

## 2. 已验证结果
- 初版 ID52：`AUTO-CHECK FAILED with 1310 mismatches`。
- 修复后 ID52：`AUTO-CHECK PASSED: 4096 valid scalars + 0 padding scalars`。
- 修复点：在 `b8c_decoder_id52` 给 LUT 输出加一级对齐寄存（`fp_vec_d1`）。

## 3. A/B 对比结果（legacy vs ID52）
- `compute_beats`: `16674 -> 5558`（理论 3x）
- 但阶段时间几乎不变（`~1.001x`）：
  - `feed_ns`: `215270 -> 215130`
  - `drain_ns`: `7290 -> 7290`
  - `total_compute_to_finish_ns`: `227780 -> 227640`
- 结论：当前系统被前端节拍/反压限制，ID 压缩带来的流量优势未充分释放。

## 4. 解码前端问题与限制
1. Parser 采用 `S_FILL/S_EMIT` 串行，fill 与 emit 不重叠，有硬气泡。  
2. FIFO 读请求带 `!fifo_ren + fifo_ren_d`，读节拍偏慢。  
3. `decoder_valid = id_valid && meta_valid`，两条链路锁步，单边慢会拖慢全链。  
4. `s_axis_tready` 在 compute 期直接受 decoder ready 影响，易产生前端阻塞。  

硬限制：
- LUT 容量：8-bit ID，最多 256 unique values。
- metadata 字段：`row_base/col_base/row_delta` 当前按 16bit 处理。

## 5. 关键文件与作用
- `frame_work.srcs/sources_1/new/b8c_top.v`  
  增加 `MODE_ID52/LUT_INIT_FILE`，切换 legacy 与 ID52 路径。
- `frame_work.srcs/sources_1/new/b8c_decoder_id52.v`  
  ID52 主解码器；包含修复用 `fp_vec_d1` 对齐。
- `frame_work.srcs/sources_1/new/stream_demux_id52.v`  
  `2:5` 分流（ID/meta）。
- `frame_work.srcs/sources_1/new/id_unpack_parser.v`  
  `2x512b -> 16周期 x 8x8bit` ID 展开。
- `frame_work.srcs/sources_1/new/value_lut_decode.v`  
  加载 `lut.hex` 并并行查表 ID->FP64。
- `frame_work.srcs/sim_1/new/tb_b8c_top_ram.sv`  
  支持 `MODE_ID52`，并加了关键时间戳打印（便于分段计时）。
- `frame_work.srcs/sim_1/tools/convert_to_b8c_hex.py`  
  生成 `compute_id_stream.hex/value_id_stream.hex/lut.hex`。
- `frame_work.srcs/sim_1/tools/compare_mode_timing.py`  
  自动跑 A/B（MODE0/1）并输出 speedup 表。

## 6. 可复现命令
```powershell
# 1) 生成 ID52 输入
C:\IC\.venv\Scripts\python.exe frame_work.srcs/sim_1/tools/convert_to_b8c_hex.py `
  --mtx C:\IC\SpMV\hpcg_16-1.mtx `
  --out-dir C:\IC\FPGA\frame_work\frame_work.srcs\sim_1\data\hpcg_16-1 `
  --vector-depth 512 `
  --x-file C:\IC\FPGA\frame_work\frame_work.srcs\sim_1\data\hpcg_16-1\x_all_ones_4096.txt

# 2) 自动 A/B 时间对比（会分别跑 MODE0/MODE1）
C:\IC\.venv\Scripts\python.exe frame_work.srcs/sim_1/tools/compare_mode_timing.py --prefix handoff

# 3) 仅复用已有日志做汇总
C:\IC\.venv\Scripts\python.exe frame_work.srcs/sim_1/tools/compare_mode_timing.py --prefix handoff --reuse-logs
```

## 7. 下一会话建议优先级
1. 优化前端 parser/fifo 读策略（减少 fill-emission 气泡，尝试重叠装载）。  
2. 放松 ID/meta 锁步推进策略（避免 `id_valid && meta_valid` 造成不必要停顿）。  
3. 增加 `s_axis_tready` 统计计数器（高/低占比）用于定量定位反压来源。  
4. 再次用 `compare_mode_timing.py` 做 A/B，验证是否出现实质 speedup。  

