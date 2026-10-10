#include "OpusBridge.h"
int sd_configure_encoder(OpusEncoder *e) {
 int r = opus_encoder_ctl(e, OPUS_SET_BITRATE(160000)); if (r) return r;
 r = opus_encoder_ctl(e, OPUS_SET_VBR(1)); if (r) return r;
 r = opus_encoder_ctl(e, OPUS_SET_VBR_CONSTRAINT(1)); if (r) return r;
 r = opus_encoder_ctl(e, OPUS_SET_SIGNAL(OPUS_SIGNAL_MUSIC)); if (r) return r;
 r = opus_encoder_ctl(e, OPUS_SET_DTX(0)); if (r) return r;
 return opus_encoder_ctl(e, OPUS_SET_COMPLEXITY(5));
}
int sd_encoder_lookahead(OpusEncoder *e) { int n=0; opus_encoder_ctl(e, OPUS_GET_LOOKAHEAD(&n)); return n; }
void sd_reset_decoder(OpusDecoder *d) { opus_decoder_ctl(d, OPUS_RESET_STATE); }
