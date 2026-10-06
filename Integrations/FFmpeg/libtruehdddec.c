/*
 * TrueHD decoder using the libtruehdd C API
 * Copyright (c) 2026 B00kerLouis
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <TrueHDDecoder.h>

#include "libavutil/channel_layout.h"
#include "libavutil/base64.h"
#include "libavutil/dict.h"
#include "libavutil/intreadwrite.h"
#include "libavutil/opt.h"
#include "avcodec.h"
#include "codec_internal.h"
#include "decode.h"

/** Private state for one externally serialized decoder instance. */
typedef struct LibTrueHDDContext {
    const AVClass *class;     ///< Option class.
    STHDDecoder *decoder;     ///< Opaque stream state owned by libtruehdd.
    STHDFrame decoded;       ///< Bounded, copied PCM and metadata for one AU.
    STHDFrameMotion motion;  ///< Sample-aligned OAMD trajectory for that AU.
    int presentation;       ///< -1 selects the fullest available presentation.
    int export_metadata;    ///< Export OAMD motion and DRC codes.
} LibTrueHDDContext;

/** Map external C API errors without exporting its enum into FFmpeg's ABI. */
static int status_error(STHDStatus status)
{
    switch (status) {
    case STHD_INVALID_ARGUMENT:   return AVERROR(EINVAL);
    case STHD_OUT_OF_MEMORY:      return AVERROR(ENOMEM);
    case STHD_UNSUPPORTED_STREAM: return AVERROR_PATCHWELCOME;
    case STHD_CORRUPT_STREAM:     return AVERROR_INVALIDDATA;
    default:                     return AVERROR_EXTERNAL;
    }
}

/** Validate the C ABI and allocate one externally serialized stream instance. */
static av_cold int libtruehdd_init(AVCodecContext *avctx)
{
    LibTrueHDDContext *s = avctx->priv_data;

    if (sthd_abi_version() != STHD_ABI_VERSION) {
        av_log(avctx, AV_LOG_ERROR, "libtruehdd C ABI version mismatch\n");
        return AVERROR_EXTERNAL;
    }
    s->decoder = sthd_decoder_create();
    if (!s->decoder)
        return AVERROR(ENOMEM);
    avctx->sample_rate = 48000;
    avctx->sample_fmt = AV_SAMPLE_FMT_S32;
    avctx->bits_per_raw_sample = 24;
    avctx->frame_size = STHD_MAX_SAMPLES;
    return 0;
}

/** Release the external instance through its owning library. */
static av_cold int libtruehdd_close(AVCodecContext *avctx)
{
    LibTrueHDDContext *s = avctx->priv_data;

    sthd_decoder_destroy(s->decoder);
    s->decoder = NULL;
    return 0;
}

/** Reset codec history and inherited metadata after seeking. */
static void libtruehdd_flush(AVCodecContext *avctx)
{
    LibTrueHDDContext *s = avctx->priv_data;

    sthd_decoder_reset(s->decoder);
}

/** Pack copied xyz data in sample-major float32 LE order. */
static int export_position_data(AVFrame *frame, const char *key, const STHDPosition positions[][STHD_MAX_CHANNELS],
                                unsigned samples, unsigned channels)
{
    uint8_t packed[STHD_MAX_SAMPLES * STHD_MAX_CHANNELS * 12];
    char encoded[AV_BASE64_SIZE(sizeof(packed))];
    unsigned count = 0;
    if (!samples || samples > STHD_MAX_SAMPLES || !channels || channels > STHD_MAX_CHANNELS)
        return AVERROR_INVALIDDATA;
    for (unsigned n = 0; n < samples; n++)
        for (unsigned c = 0; c < channels; c++) {
            const STHDPosition *p = &positions[n][c];
            const float values[3] = { p->x, p->y, p->z };
            for (unsigned axis = 0; axis < 3; axis++) {
                uint32_t bits;
                memcpy(&bits, &values[axis], sizeof(bits));
                AV_WL32(packed + count, bits);
                count += 4;
            }
        }
    av_base64_encode(encoded, sizeof(encoded), packed, count);
    return av_dict_set(&frame->metadata, key, encoded, 0);
}

/** Copy metadata values; no borrowed libtruehdd pointers escape into AVFrame. */
static int export_metadata(AVFrame *frame, const STHDFrame *decoded,
                           const STHDFrameMotion *motion, int layer, uint32_t drc_valid)
{
    int ret;

    ret = av_dict_set_int(&frame->metadata, "truehdd.presentation", layer, 0);
    if (ret < 0)
        return ret;
    ret = av_dict_set_int(&frame->metadata, "truehdd.drc_gain_valid",
                         !!(drc_valid & (1U << layer)), 0);
    if (ret < 0)
        return ret;
    if (drc_valid & (1U << layer)) {
        ret = av_dict_set_int(&frame->metadata, "truehdd.drc_gain_code",
                             decoded->drc_gain_code[layer], 0);
        if (ret < 0)
            return ret;
    }
    if (layer != 3)
        return ret;
    ret = av_dict_set_int(&frame->metadata, "truehdd.positions_dynamic",
                         motion->positions_dynamic, 0);
    if (ret < 0)
        return ret;
    if (motion->update_count) {
        ret = av_dict_set_int(&frame->metadata, "truehdd.oamd.sample_offset",
                             motion->updates[0].sample_offset, 0);
        if (ret < 0)
            return ret;
        ret = av_dict_set_int(&frame->metadata, "truehdd.oamd.ramp_samples",
                             motion->updates[0].ramp_samples, 0);
        if (ret < 0)
            return ret;
        ret = export_position_data(frame, "truehdd.oamd.targets_xyz_f32le",
                                   &motion->updates[0].targets, 1, motion->channels);
        if (ret < 0)
            return ret;
    }
    if (motion->positions_dynamic) {
        ret = export_position_data(frame, "truehdd.motion_xyz_f32le", motion->positions,
                                   motion->samples, motion->channels);
        if (ret < 0)
            return ret;
        ret = av_dict_set_int(&frame->metadata, "truehdd.motion_valid_samples",
                             motion->valid_samples, 0);
        if (ret < 0)
            return ret;
        ret = av_dict_set_int(&frame->metadata, "truehdd.snapshot_quantized", 1, 0);
        if (ret < 0)
            return ret;
    }
    ret = av_dict_set_int(&frame->metadata, "truehdd.positions_valid",
                         decoded->positions_valid, 0);
    if (ret < 0 || !decoded->positions_valid)
        return ret;
    ret = av_dict_set(&frame->metadata, "truehdd.coordinates", "normalized_room", 0);
    if (ret < 0)
        return ret;
    ret = av_dict_set_int(&frame->metadata, "truehdd.xy_denominator", 31, 0);
    if (ret < 0)
        return ret;
    ret = av_dict_set_int(&frame->metadata, "truehdd.z_denominator", 15, 0);
    if (ret < 0)
        return ret;
    for (unsigned i = 0; i < decoded->element_channels; i++) {
        const STHDPosition *p = &decoded->positions[i];
        const int numerators[3] = {
            lroundf(p->x * 31), lroundf(p->y * 31), lroundf(p->z * 15)
        };
        char key[64];

        snprintf(key, sizeof(key), "truehdd.element.%u.kind", i);
        ret = av_dict_set(&frame->metadata, key, i ? "object" : "lfe", 0);
        if (ret < 0)
            return ret;
        for (unsigned axis = 0; axis < 3; axis++) {
            snprintf(key, sizeof(key), "truehdd.element.%u.%c", i, "xyz"[axis]);
            ret = av_dict_set_int(&frame->metadata, key, numerators[axis], 0);
            if (ret < 0)
                return ret;
        }
    }
    return 0;
}

/** Decode one framed AU; FFmpeg owns packet timestamps and output buffers. */
static int libtruehdd_decode(AVCodecContext *avctx, AVFrame *frame,
                           int *got_frame, AVPacket *pkt)
{
    LibTrueHDDContext *s = avctx->priv_data;
    AVChannelLayout layout = { 0 };
    STHDStatus status;
    int layer, length, ret;
    int32_t *output;

    *got_frame = 0;
    if (!pkt->size)
        return 0;
    if (pkt->size < 4) {
        sthd_decoder_reset(s->decoder);
        return AVERROR_INVALIDDATA;
    }
    length = (AV_RB16(pkt->data) & 0xfff) * 2;
    if (length < 4 || length > STHD_MAX_ACCESS_UNIT || length > pkt->size) {
        sthd_decoder_reset(s->decoder);
        return AVERROR_INVALIDDATA;
    }

    status = sthd_decoder_set_strict_pcm_checksum(s->decoder, !!(avctx->err_recognition & AV_EF_EXPLODE));
    if (status != STHD_OK)
        return status_error(status);
    status = sthd_decode_access_unit(s->decoder, pkt->data, length, &s->decoded);
    if (status == STHD_NEED_RESTART)
        return length; // Drop preroll until the parser provides a major sync.
    if (status != STHD_OK) {
        av_log(avctx, AV_LOG_ERROR, "libtruehdd: %s (%s)\n",
               sthd_status_string(status), sthd_decoder_error(s->decoder));
        sthd_decoder_reset(s->decoder);
        return status_error(status);
    }
    status = sthd_decoder_motion(s->decoder, &s->motion);
    if (status != STHD_OK)
        return status_error(status);
    {
        STHDPCMChecksum checksum;
        status = sthd_decoder_pcm_checksum(s->decoder, &checksum);
        if (status != STHD_OK)
            return status_error(status);
        if (checksum.mismatched_layers) {
            frame->flags |= AV_FRAME_FLAG_CORRUPT;
            av_log(avctx, AV_LOG_WARNING, "libtruehdd: PCM checksum mismatch, presentation mask 0x%x\n",
                   checksum.mismatched_layers);
        }
    }
    layer = s->presentation < 0 ? s->decoded.presentations - 1 : s->presentation;
    if (layer >= (int)s->decoded.presentations) {
        av_log(avctx, AV_LOG_ERROR, "Requested presentation is absent\n");
        sthd_decoder_reset(s->decoder);
        return AVERROR_PATCHWELCOME;
    }
    switch (layer) {
    case 0: layout = (AVChannelLayout)AV_CHANNEL_LAYOUT_STEREO; break;
    case 1: layout = (AVChannelLayout)AV_CHANNEL_LAYOUT_5POINT1; break;
    case 2: layout = (AVChannelLayout)AV_CHANNEL_LAYOUT_7POINT1; break;
    case 3:
        // Positional elements are not a speaker layout inferred from a count.
        layout.order = AV_CHANNEL_ORDER_UNSPEC;
        layout.nb_channels = s->decoded.element_channels;
        break;
    }
    avctx->profile = s->decoded.element_channels ? AV_PROFILE_TRUEHD_ATMOS : AV_PROFILE_UNKNOWN;
    av_channel_layout_uninit(&avctx->ch_layout);
    avctx->ch_layout = layout;
    frame->nb_samples = s->decoded.samples;
    ret = ff_get_buffer(avctx, frame, 0);
    if (ret < 0)
        goto fail;
    if (avctx->pkt_timebase.num > 0 && avctx->pkt_timebase.den > 0)
        frame->duration = av_rescale_q(s->decoded.samples,
                                      (AVRational){ 1, s->decoded.sample_rate },
                                      avctx->pkt_timebase);
    output = (int32_t *)frame->data[0];
    for (unsigned i = 0; i < s->decoded.samples * s->decoded.channels[layer]; i++)
        output[i] = s->decoded.pcm[layer][i] * 256;
    if (s->export_metadata) {
        ret = export_metadata(frame, &s->decoded, &s->motion, layer,
                              sthd_decoder_drc_valid(s->decoder));
        if (ret < 0)
            goto fail;
    }
    if (length >= 8 && AV_RB32(pkt->data + 4) == 0xf8726fba)
        frame->flags |= AV_FRAME_FLAG_KEY;
    *got_frame = 1;
    return length;

fail:
    av_frame_unref(frame);
    sthd_decoder_reset(s->decoder);
    return ret;
}

#define OFFSET(x) offsetof(LibTrueHDDContext, x)
#define FLAGS (AV_OPT_FLAG_AUDIO_PARAM | AV_OPT_FLAG_DECODING_PARAM)
static const AVOption options[] = {
    { "presentation", "Encoded presentation to decode", OFFSET(presentation),
      AV_OPT_TYPE_INT, { .i64 = -1 }, -1, 3, FLAGS, .unit = "presentation" },
    { "auto", "Fullest encoded presentation", 0, AV_OPT_TYPE_CONST,
      { .i64 = -1 }, 0, 0, FLAGS, .unit = "presentation" },
    { "stereo", "Encoded stereo PCM", 0, AV_OPT_TYPE_CONST,
      { .i64 = 0 }, 0, 0, FLAGS, .unit = "presentation" },
    { "5.1", "Encoded 5.1 PCM", 0, AV_OPT_TYPE_CONST,
      { .i64 = 1 }, 0, 0, FLAGS, .unit = "presentation" },
    { "7.1", "Encoded 7.1 PCM", 0, AV_OPT_TYPE_CONST,
      { .i64 = 2 }, 0, 0, FLAGS, .unit = "presentation" },
    { "elements", "Immersive elements in OAMD output order", 0, AV_OPT_TYPE_CONST,
      { .i64 = 3 }, 0, 0, FLAGS, .unit = "presentation" },
    { "export_metadata", "Export fixed OAMD and unapplied DRC metadata",
      OFFSET(export_metadata), AV_OPT_TYPE_BOOL, { .i64 = 1 }, 0, 1, FLAGS, .unit = NULL },
    { .name = NULL }
};

static const AVClass libtruehdd_class = {
    .class_name = "libtruehdd decoder",
    .item_name  = av_default_item_name,
    .option    = options,
    .version   = LIBAVUTIL_VERSION_INT,
};

const FFCodec ff_libtruehdd_decoder = {
    .p.name         = "libtruehdd",
    CODEC_LONG_NAME("TrueHD decoder using libtruehdd"),
    .p.type         = AVMEDIA_TYPE_AUDIO,
    .p.id           = AV_CODEC_ID_TRUEHD,
    .p.priv_class   = &libtruehdd_class,
    .p.wrapper_name = "libtruehdd",
    .p.capabilities = AV_CODEC_CAP_DR1 | AV_CODEC_CAP_CHANNEL_CONF,
    .priv_data_size = sizeof(LibTrueHDDContext),
    .init           = libtruehdd_init,
    .close          = libtruehdd_close,
    .flush          = libtruehdd_flush,
    FF_CODEC_DECODE_CB(libtruehdd_decode),
    CODEC_SAMPLEFMTS(AV_SAMPLE_FMT_S32),
    CODEC_SAMPLERATES(48000),
};
