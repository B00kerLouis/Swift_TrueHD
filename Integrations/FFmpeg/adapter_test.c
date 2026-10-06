/* SPDX-License-Identifier: LGPL-2.1-or-later */
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <TrueHDDecoder.h>
#include <libavcodec/avcodec.h>
#include <libavutil/dict.h>
#include <libavutil/base64.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/opt.h>

static void require(int condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

static AVCodecContext *open_decoder(const AVCodec *codec, const char *presentation,
                                    int export_metadata)
{
    AVCodecContext *context = avcodec_alloc_context3(codec);

    require(context != NULL, "allocate context");
    context->pkt_timebase = (AVRational){ 1, 48000 };
    require(av_opt_set(context->priv_data, "presentation", presentation, 0) == 0,
            "set presentation");
    require(av_opt_set_int(context->priv_data, "export_metadata", export_metadata, 0) == 0,
            "set metadata export");
    require(avcodec_open2(context, codec, NULL) == 0, "open libtruehdd");
    return context;
}

static int64_t metadata_int(const AVFrame *frame, const char *key)
{
    AVDictionaryEntry *entry = av_dict_get(frame->metadata, key, NULL, 0);
    char *end;
    int64_t result;

    require(entry != NULL, key);
    result = strtoll(entry->value, &end, 10);
    require(*end == 0, "integer metadata");
    return result;
}

int main(int argc, char **argv)
{
    const char *presentations[] = { "stereo", "5.1", "7.1", "elements" };
    const AVCodec *codec = avcodec_find_decoder_by_name("libtruehdd");
    AVCodecContext *continuous, *seeking;
    AVFrame *frame = av_frame_alloc(), *seek_frame = av_frame_alloc();
    AVFrame *retained = av_frame_alloc();
    AVPacket *packet = av_packet_alloc();
    STHDDecoder *core = sthd_decoder_create();
    STHDFrame decoded;
    FILE *input, *reference;
    uint8_t header[4], bytes[STHD_MAX_ACCESS_UNIT], packed[3];
    uint8_t first_au[STHD_MAX_ACCESS_UNIT], second_au[STHD_MAX_ACCESS_UNIT];
    unsigned first_size = 0, second_size = 0;
    int32_t retained_samples[STHD_MAX_SAMPLES * STHD_MAX_CHANNELS];
    int retained_count = 0, layer;
    uint64_t samples = 0, access_units = 0, restarts = 0, missing_positions = 0;
    int resumed_metadata = 0;

    require(argc == 4, "Usage: adapter_test INPUT.mlp REFERENCE.pcm|- LAYER(0..3)");
    layer = atoi(argv[3]);
    require(layer >= 0 && layer < 4, "presentation index");
    require(codec && frame && seek_frame && retained && packet && core, "allocate test state");
    input = fopen(argv[1], "rb");
    reference = strcmp(argv[2], "-") ? fopen(argv[2], "rb") : NULL;
    require(input && (!strcmp(argv[2], "-") || reference), "open input/reference");
    continuous = open_decoder(codec, presentations[layer], 1);
    seeking = open_decoder(codec, presentations[layer], 1);
    size_t header_bytes;
    while ((header_bytes = fread(header, 1, 4, input))) {
        require(header_bytes == 4, "complete header");
        unsigned size = ((header[0] & 15) * 256 + header[1]) * 2;
        int major;

        require(size >= 4 && size <= sizeof(bytes), "bounded AU length");
        memcpy(bytes, header, 4);
        require(fread(bytes + 4, 1, size - 4, input) == size - 4, "complete AU");
        if (access_units < 2) {
            memcpy(access_units ? second_au : first_au, bytes, size);
            if (access_units)
                second_size = size;
            else
                first_size = size;
        }
        major = size >= 8 && memcmp(bytes + 4, "\xf8\x72\x6f\xba", 4) == 0;
        if (major) {
            avcodec_flush_buffers(seeking);
            ++restarts;
        }
        require(sthd_decode_access_unit(core, bytes, size, &decoded) == STHD_OK,
                "core decode for metadata mapping");
        STHDPCMChecksum integrity;
        require(sthd_decoder_pcm_checksum(core, &integrity) == STHD_OK, "PCM checksum evidence");
        require(av_new_packet(packet, size) == 0, "allocate packet");
        memcpy(packet->data, bytes, size);
        packet->pts = packet->dts = 1234567 + (int64_t)samples;
        packet->duration = 40;
        require(avcodec_send_packet(continuous, packet) == 0, "continuous send");
        require(avcodec_send_packet(seeking, packet) == 0, "seek send");
        require(avcodec_receive_frame(continuous, frame) == 0, "continuous receive");
        require(avcodec_receive_frame(seeking, seek_frame) == 0, "seek receive");
        require(frame->format == AV_SAMPLE_FMT_S32 && frame->sample_rate == 48000,
                "S32/48 kHz output");
        require(frame->pts == packet->pts && seek_frame->pts == packet->pts,
                "packet PTS preserved across flush");
        require(frame->duration == frame->nb_samples, "final trim duration");
        require(frame->nb_samples == (int)decoded.samples &&
                frame->ch_layout.nb_channels == (int)decoded.channels[layer], "PCM dimensions");
        require((!!(frame->flags & AV_FRAME_FLAG_KEY)) == major, "major sync key flag");
        if (layer == 3)
            require(frame->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC,
                    "element count does not invent a speaker layout");
        else
            require(frame->ch_layout.order == AV_CHANNEL_ORDER_NATIVE,
                    "core speaker layout");
        require(!!(frame->flags & AV_FRAME_FLAG_CORRUPT) == !!integrity.mismatched_layers,
                "PCM mismatch marks the AVFrame corrupt without changing PCM");
        require(metadata_int(frame, "truehdd.presentation") == layer,
                "selected presentation");
        unsigned known_drc = !!(sthd_decoder_drc_valid(core) & (1U << layer));
        require(metadata_int(frame, "truehdd.drc_gain_valid") == known_drc,
                "unapplied DRC validity");
        if (known_drc)
            require(metadata_int(frame, "truehdd.drc_gain_code") == decoded.drc_gain_code[layer],
                    "unapplied DRC gain code");
        if (!metadata_int(seek_frame, "truehdd.drc_gain_valid"))
            require(!av_dict_get(seek_frame->metadata, "truehdd.drc_gain_code", NULL, 0),
                    "unavailable DRC is not fabricated after seek");
        if (layer == 3) {
            int valid = metadata_int(seek_frame, "truehdd.positions_valid");
            if (!valid) {
                ++missing_positions;
                require(!av_dict_get(seek_frame->metadata, "truehdd.element.0.x", NULL, 0),
                        "missing positions are not fabricated");
            } else if (missing_positions) {
                resumed_metadata = 1;
            }
            if (missing_positions && av_dict_get(seek_frame->metadata,
                    "truehdd.oamd.targets_xyz_f32le", NULL, 0))
                resumed_metadata = 1;
            require(metadata_int(frame, "truehdd.positions_valid") == decoded.positions_valid,
                    "OAMD validity mapped");
            STHDFrameMotion motion;
            require(sthd_decoder_motion(core, &motion) == STHD_OK, "core motion view");
            require(metadata_int(frame, "truehdd.positions_dynamic") == motion.positions_dynamic,
                    "movement flag preserved");
            if (motion.positions_dynamic) {
                AVDictionaryEntry *entry = av_dict_get(frame->metadata, "truehdd.motion_xyz_f32le", NULL, 0);
                uint8_t packed[STHD_MAX_SAMPLES * STHD_MAX_CHANNELS * 12];
                require(entry && av_base64_decode(packed, entry->value, sizeof(packed)) ==
                        (int)(motion.samples * motion.channels * 12), "complete owned motion payload");
                require(metadata_int(frame, "truehdd.motion_valid_samples") == (int64_t)motion.valid_samples,
                        "motion validity bitmap");
                unsigned at = 0;
                for (unsigned n = 0; n < motion.samples; ++n)
                    for (unsigned c = 0; c < motion.channels; ++c) {
                        const float xyz[3] = { motion.positions[n][c].x, motion.positions[n][c].y, motion.positions[n][c].z };
                        for (unsigned axis = 0; axis < 3; ++axis) {
                            uint32_t expected;
                            memcpy(&expected, &xyz[axis], sizeof(expected));
                            require(AV_RL32(packed + at) == expected, "sample-exact motion metadata");
                            at += 4;
                        }
                    }
            }
            if (motion.update_count) {
                AVDictionaryEntry *entry = av_dict_get(frame->metadata, "truehdd.oamd.targets_xyz_f32le", NULL, 0);
                uint8_t packed[STHD_MAX_CHANNELS * 12];
                require(entry && av_base64_decode(packed, entry->value, sizeof(packed)) ==
                        (int)(motion.channels * 12), "owned incoming target payload");
                for (unsigned c = 0; c < motion.channels; ++c) {
                    const STHDPosition *p = &motion.updates[0].targets[c];
                    const float xyz[3] = { p->x, p->y, p->z };
                    for (unsigned axis = 0; axis < 3; ++axis) {
                        uint32_t expected;
                        memcpy(&expected, &xyz[axis], sizeof(expected));
                        require(AV_RL32(packed + c * 12 + axis * 4) == expected, "exact target coordinates");
                    }
                }
            }
            if (!decoded.positions_valid)
                require(!av_dict_get(frame->metadata, "truehdd.element.0.x", NULL, 0), "unknown ramp coordinates not fabricated");
            for (unsigned c = 0; decoded.positions_valid && c < decoded.element_channels; c++) {
                const float coordinates[] = { decoded.positions[c].x,
                                               decoded.positions[c].y,
                                               decoded.positions[c].z };
                for (unsigned axis = 0; axis < 3; axis++) {
                    char key[64];
                    int denominator = axis == 2 ? 15 : 31;
                    snprintf(key, sizeof(key), "truehdd.element.%u.%c", c, "xyz"[axis]);
                    require(metadata_int(frame, key) == lroundf(coordinates[axis] * denominator),
                            "OAMD coordinate preserved");
                }
            }
        }
        unsigned count = decoded.samples * decoded.channels[layer];
        const int32_t *pcm = (const int32_t *)frame->data[0];
        require(seek_frame->nb_samples == frame->nb_samples &&
                memcmp(pcm, seek_frame->data[0], count * sizeof(*pcm)) == 0,
                "flush/restart equals continuous PCM");
        for (unsigned i = 0; i < count; i++) {
            int32_t expected = decoded.pcm[layer][i];
            if (reference) {
                require(fread(packed, 1, 3, reference) == 3, "reference sample");
                uint32_t value = packed[0] | ((uint32_t)packed[1] << 8) |
                                 ((uint32_t)packed[2] << 16);
                expected = value < 0x800000 ? value : (int64_t)value - 0x1000000;
            }
            require(pcm[i] == expected * 256, "pre-entropy reference and S32 alignment");
        }
        if (!access_units) {
            require(av_frame_ref(retained, frame) == 0, "retain frame");
            memcpy(retained_samples, pcm, count * sizeof(*pcm));
            retained_count = count;
        }
        samples += frame->nb_samples;
        ++access_units;
        av_frame_unref(frame);
        av_frame_unref(seek_frame);
        av_packet_unref(packet);
        require(avcodec_receive_frame(continuous, frame) == AVERROR(EAGAIN),
                "one frame per AU and bounded drain");
    }
    require(feof(input) && !ferror(input) && (!reference || fgetc(reference) == EOF),
            "exact stream/reference end");
    require(access_units && restarts > 1, "multiple random-access restarts exercised");
    if (layer == 3)
        require(missing_positions && resumed_metadata, "late OAMD arrives after seek");
    require(avcodec_send_packet(continuous, NULL) == 0 &&
            avcodec_receive_frame(continuous, frame) == AVERROR_EOF, "drain to EOF");
    avcodec_flush_buffers(continuous);
    require(av_new_packet(packet, 3) == 0, "short packet allocation");
    memset(packet->data, 0, 3);
    int result = avcodec_send_packet(continuous, packet);
    if (!result)
        result = avcodec_receive_frame(continuous, frame);
    require(result == AVERROR_INVALIDDATA, "truncated packet maps to invalid data");
    av_packet_unref(packet);
    avcodec_flush_buffers(continuous);
    require(av_new_packet(packet, second_size) == 0, "preroll allocation");
    memcpy(packet->data, second_au, second_size);
    require(avcodec_send_packet(continuous, packet) == 0 &&
            avcodec_receive_frame(continuous, frame) == AVERROR(EAGAIN),
            "preroll skipped until major sync");
    av_packet_unref(packet);
    require(av_new_packet(packet, first_size) == 0, "recovery allocation");
    memcpy(packet->data, first_au, first_size);
    packet->data[first_size / 2] ^= 1;
    result = avcodec_send_packet(continuous, packet);
    if (!result)
        result = avcodec_receive_frame(continuous, frame);
    require(result == AVERROR_INVALIDDATA, "corrupt packet error mapping");
    av_packet_unref(packet);
    require(av_new_packet(packet, first_size) == 0, "valid recovery allocation");
    memcpy(packet->data, first_au, first_size);
    packet->pts = 9000000;
    require(avcodec_send_packet(continuous, packet) == 0 &&
            avcodec_receive_frame(continuous, frame) == 0 && frame->pts == packet->pts,
            "valid major sync recovers after corruption");
    require(memcmp(frame->data[0], retained_samples,
                   retained_count * sizeof(*retained_samples)) == 0,
            "recovery PCM exact");
    av_frame_unref(frame);
    AVCodecContext *no_metadata = open_decoder(codec, presentations[layer], 0);
    require(avcodec_send_packet(no_metadata, packet) == 0 &&
            avcodec_receive_frame(no_metadata, frame) == 0 && !frame->metadata,
            "metadata can be disabled without changing PCM");
    require(memcmp(frame->data[0], retained_samples,
                   retained_count * sizeof(*retained_samples)) == 0,
            "disabled metadata PCM exact");
    avcodec_free_context(&no_metadata);
    if (decoded.presentations == 3) {
        AVCodecContext *absent = open_decoder(codec, "elements", 1);
        result = avcodec_send_packet(absent, packet);
        if (!result)
            result = avcodec_receive_frame(absent, seek_frame);
        require(result == AVERROR_PATCHWELCOME, "absent presentation error mapping");
        avcodec_free_context(&absent);
    }
    avcodec_free_context(&continuous);
    avcodec_free_context(&seeking);
    require(memcmp(retained->data[0], retained_samples,
                   retained_count * sizeof(*retained_samples)) == 0,
            "retained AVFrame owns PCM after decode/flush/close");
    require(metadata_int(retained, "truehdd.presentation") == layer,
            "retained AVFrame owns metadata");
    sthd_decoder_destroy(core);
    av_frame_free(&retained);
    av_frame_free(&seek_frame);
    av_frame_free(&frame);
    av_packet_free(&packet);
    if (reference)
        fclose(reference);
    fclose(input);
    printf("layer=%d AUs=%llu samples=%llu restarts=%llu: PCM/PTS/trim/metadata/flush/lifetime/errors passed\n",
           layer, (unsigned long long)access_units, (unsigned long long)samples,
           (unsigned long long)restarts);
    return 0;
}
