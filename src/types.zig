pub const H264Type = enum { Annex_B, AVCC };

pub const TypeError = error{
    NotMaintainedType,
};

pub const NALError = error{
    NoStartCode,
    InvalidData,
    OutOfMemory,
    FMONotSupported,
    PPSNotFound,
    SPSNotFound,
};

pub const NALType = enum(u5) {
    H264_NAL_UNSPECIFIED = 0,
    H264_NAL_SLICE = 1, // 非 IDR 图像的编码条带
    H264_NAL_DPA = 2, // 数据分区 A
    H264_NAL_DPB = 3, // 数据分区 B
    H264_NAL_DPC = 4, // 数据分区 C
    H264_NAL_IDR_SLICE = 5, // IDR 图像编码条带 (关
    H264_NAL_SEI = 6, // 补充增强信息
    H264_NAL_SPS = 7, // 序列参数集
    H264_NAL_PPS = 8, // 图像参数集
    H264_NAL_AUD = 9, // 访问单元分隔符
    H264_NAL_END_SEQUENCE = 10, // 序列结束
    H264_NAL_END_STREAM = 11, // 码流结束
    H264_NAL_FILLER_DATA = 12, // 填充数据
    H264_NAL_SPS_EXT = 13, // SPS 扩展
    H264_NAL_PREFIX = 14, // 前缀 NAL (用于
    // SVC/MVC)
    H264_NAL_SUB_SPS = 15, // 子集 SPS (用于 SVC)
    H264_NAL_DPS = 16, // 深度参数集 (3D)
    H264_NAL_RESERVED17 = 17, // 保留
    H264_NAL_RESERVED18 = 18, // 保留
    H264_NAL_AUXILIARY_SLICE = 19, // 辅助编码图像
    H264_NAL_EXTEN_SLICE = 20, // 扩展条带 (SVC/MVC)
    H264_NAL_DEPTH_EXTEN_SLICE = 21, // 深度扩展条带 (3D)
    // 22-23 H264_NAL_RESERVED22/23     保留
    // 24-31 H264_NAL_UNSPECIFIED24-31  未指定 (RTP 用
    //                                  24=STAP-A, 28=FU-A)
    //
    // 重要补充：类型 14 和 20（SVC/MVC 扩展）的 NAL unit header 不是
};


pub const NALUnit = struct {
    data: []u8,
    nal_type: NALType,
    start_code_len: u8,
};
