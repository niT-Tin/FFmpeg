//H.264 解码器是 libavcodec 中最复杂的实现之一，涉及约 30 个核心文件。入口点在 h264dec.c，依赖 h264dec.h 作为内部 API 头，以及共享的 NAL 单元解析代码 (h2645_parse.c)。
//
//  解码流程分 6 个阶段：
//
//  ---
//  阶段 1: 帧级入口 → NAL 单元解析
//
//  h264dec.c:h264_decode_frame()    ← AVCodec 框架调用的入口
//    → h2645_parse.c:ff_h2645_packet_split()   拆分 Annex B 字节流为 NAL 单元
//    → h264dec.c:decode_nal_units()             逐 NAL 单元分发处理
//
//  h264_decode_frame 是 FFmpeg 框架通过 decode.h 的 FFCodec.decode 回调调用的入口。它调用 h2645_parse.c 中的共享函数将原始字节流切分为 NAL 单元（以 start code 0x000001 分隔）。
//
//  ---
//  阶段 2: NAL 单元分发
//
//  decode_nal_units() 根据 NAL 类型走不同分支：
//
//  ┌────────────┬────────────────────────────────────────┬──────────────┐
//  │  NAL 类型  │                处理函数                │     文件     │
//  ├────────────┼────────────────────────────────────────┼──────────────┤
//  │ SPS (7)    │ ff_h264_decode_seq_parameter_set()     │ h264_ps.c    │
//  ├────────────┼────────────────────────────────────────┼──────────────┤
//  │ PPS (8)    │ ff_h264_decode_picture_parameter_set() │ h264_ps.c    │
//  ├────────────┼────────────────────────────────────────┼──────────────┤
//  │ SEI (6)    │ ff_h264_sei_decode()                   │ h264_sei.c   │
//  ├────────────┼────────────────────────────────────────┼──────────────┤
//  │ 切片 (1,5) │ ff_h264_queue_decode_slice()           │ h264_slice.c │
//  └────────────┴────────────────────────────────────────┴──────────────┘
//
//  参数集解析 (h264_ps.c) 负责解码 SPS（分辨率、profile/level、VUI）和 PPS（熵编码模式、去块滤波参数、量化矩阵）。
//
//  ---
//  阶段 3: 切片级解码
//
//  h264_slice.c:h264_frame_start()      ← 新帧开始，初始化参考帧
//  h264_slice.c:h264_slice_header_parse() ← 解析切片头（类型、QP、参考列表）
//  h264_slice.c:ff_h264_execute_decode_slices() → 多线程分派切片解码
//    h264_slice.c:decode_slice()          ← 单切片解码（可能多线程并行）
//
//  h264_frame_start 通过 h264_picture.c 管理 DPB（解码图像缓冲区）：ff_h264_ref_picture、ff_h264_unref_picture、ff_h264_field_end。
//
//  ---
//  阶段 4: 熵解码 → 宏块级处理
//
//  切片解码后进入宏块循环。每个宏块（16×16）按两种模式处理：
//
//  CABAC 路径 (h264_cabac.c):
//  ff_h264_decode_mb_cabac()
//    → decode_cabac_mb_skip()         跳转宏块判断
//    → decode_cabac_mb_type()         宏块类型（I/P/B）
//    → decode_cabac_mb_ref()          参考帧索引
//    → decode_cabac_mb_mvd()          运动矢量差
//    → decode_cabac_luma_residual()   亮度残差系数
//    → decode_cabac_residual_dc/nondc() 色度残差系数
//
//  CAVLC 路径 (h264_cavlc.c):
//  ff_h264_decode_mb_cavlc()
//    → decode_residual() / decode_luma_residual()
//
//  ---
//  阶段 5: 宏块重建
//
//  h264_mb.c:ff_h264_hl_decode_mb()   ← 核心重建函数
//    → h264_mb.c:hl_decode_mb_predict_luma()  帧内/帧间预测合成
//    → h264_mb_template.c:FUNC(hl_decode_mb)   位深参数化模板
//    → h264_mb.c:hl_decode_mb_idct_luma()      逆变换 + 残差加回
//
//  预测部分依赖：
//  - h264pred.c 的 ff_h264_pred_init() — 初始化 4×4/8×8/16×16 帧内预测函数指针
//  - h264_direct.c 的 ff_h264_direct_ref_list_init() — B 帧直接/跳转模式的运动矢量推导
//  - h264_mvpred.h — 运动矢量预测（空间相邻 + 时间共位）
//
//  DSP 分发：
//  - h264dsp.c:ff_h264dsp_init() — 初始化去块滤波/IDCT/运动补偿函数指针
//  - h264idct_template.c — 位深参数化的 4×4/8×8 逆 DCT
//  - h264qpel_template.c — 1/4 像素运动补偿
//
//  ---
//  阶段 6: 去块滤波 + 输出
//
//  h264_loopfilter.c                   ← 环路去块滤波（计算边界强度，逐边滤波）
//  h264dec.c:finalize_frame()          ← 帧完成处理
//  h264dec.c:output_frame()            ← 输出到显示队列
//
//  去块滤波是 H.264 的重要特性——对宏块边界进行平滑，消除块效应。h264_loopfilter.c 计算边界强度（Bs=0~4），对亮度/色度分量应用不同强度的滤波。
//
//  ---
//  依赖层次总结
//
//  公开API层:     avcodec.h  ← FFmpeg 调用者使用
//  内部框架:      decode.h, codec_internal.h, internal.h
//                ↓
//  协调层:       h264dec.c (帧级) → h264_slice.c (切片级)
//                ↓                      ↓
//  解析层:       h264_ps.c          h264_parse.c, h2645_parse.c
//                ↓                      ↓
//  熵解码:                           h264_cabac.c / h264_cavlc.c
//                ↓                      ↓
//  重建层:       h264_mb.c (宏块重建) + h264pred.c (帧内预测)
//                + h264_direct.c (B帧MV推导)
//                ↓
//  后处理:       h264_loopfilter.c (去块滤波)
//                ↓
//  显示:         h264dec.c:output_frame()
//
//  参考帧管理
//
//  h264_refs.c 负责维护 DPB：
//  - h264_initialise_ref_list() — 构建 P/B 切片参考帧列表（List0/List1）
//  - ff_h264_decode_ref_pic_marking() — 解析 MMCO（内存管理控制操作）命令
//  - ff_h264_decode_ref_pic_list_reordering() — 参考帧列表重排序
//
//  多线程
//
//  h264_slice.c:ff_h264_execute_decode_slices() 将切片分发到多个线程并行解码，每个线程独立执行熵解码和宏块重建。线程同步通过 pthread_frame.c 的帧级线程框架实现。
