#include "avcodec.h"
#include "codec.h"
#include "codec_internal.h"
#include "packet.h"
#include "codec_id.h"

extern int my_zigh264(AVCodecContext *ctx, AVFrame *frame, int *got_packet, AVPacket *pkt);

const FFCodec ff_myzigh264_decoder = {
  .p.name = "myzigh264",
  CODEC_LONG_NAME("Zig Custom h264 Codec"),
  .p.type = AVMEDIA_TYPE_VIDEO,
  .p.id = AV_CODEC_ID_MYZIGH264,
  .p.capabilities = AV_CODEC_CAP_DR1,
  FF_CODEC_DECODE_CB(my_zigh264),
};
