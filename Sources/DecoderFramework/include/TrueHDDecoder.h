/* SPDX-License-Identifier: AGPL-3.0-only */
#ifndef STHD_DECODER_H
#define STHD_DECODER_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define STHD_MAX_CHANNELS 16
#define STHD_MAX_SAMPLES 40
#define STHD_MAX_ACCESS_UNIT 8190
#define STHD_ABI_VERSION 2

typedef enum STHDStatus {
    STHD_OK = 0,
    STHD_INVALID_ARGUMENT,
    STHD_CORRUPT_STREAM,
    STHD_UNSUPPORTED_STREAM,
    STHD_NEED_RESTART,
    STHD_BUFFER_TOO_SMALL,
    STHD_DEVICE_UNAVAILABLE,
    STHD_UNKNOWN_LAYOUT,
    STHD_OUT_OF_MEMORY,
    STHD_UNSUPPORTED_OUTPUT,
    STHD_AUDIO_FAILURE,
    STHD_TIMEOUT
} STHDStatus;
typedef enum STHDSpeaker {
    STHD_FL,
    STHD_FR,
    STHD_FC,
    STHD_LFE,
    STHD_BL,
    STHD_BR,
    STHD_SL,
    STHD_SR,
    STHD_TFL,
    STHD_TFR,
    STHD_TBL,
    STHD_TBR,
    STHD_TML,
    STHD_TMR,
    STHD_FWL,
    STHD_FWR
} STHDSpeaker;
typedef struct STHDLayout {
    uint32_t channels;
    /* Physical device order, not just a count. Each label must be unique. */
    STHDSpeaker speakers[STHD_MAX_CHANNELS];
} STHDLayout;
typedef struct STHDPosition {
    float x, y, z;
} STHDPosition;
typedef struct STHDFrame {
    uint32_t sample_rate, samples, presentations, element_channels;
    uint64_t first_sample;
    uint32_t channels[4];
    /* Signed, right-aligned 24-bit PCM. Presentations 0/1/2 use
       FL FR FC LFE BL BR SL SR (5.1 uses SL SR in slots 4/5).
       Presentation 3 uses bitstream ch_assign / OAMD element order. */
    int32_t pcm[4][STHD_MAX_SAMPLES * STHD_MAX_CHANNELS];
    STHDPosition positions[STHD_MAX_CHANNELS];
    uint32_t positions_valid;
    /* DRC is reported, never silently applied to lossless PCM. */
    int32_t drc_gain_code[4];
} STHDFrame;
typedef struct STHDDecoder STHDDecoder;

/* One instance per stream, externally serialized. AU decode is transactional:
   errors leave stream state intact. A new stream must begin at a major sync. */
STHDDecoder *sthd_decoder_create(void);
void sthd_decoder_destroy(STHDDecoder *decoder);
void sthd_decoder_reset(STHDDecoder *decoder);
const char *sthd_decoder_error(const STHDDecoder *decoder);
const char *sthd_status_string(STHDStatus status);
STHDStatus sthd_decode_access_unit(STHDDecoder *decoder, const uint8_t *data, size_t bytes,
                                   STHDFrame *frame);
/* Input/output may not overlap. Float output is normalized to 24-bit full scale,
   may exceed +/-1 after summing, and is never limited or clipped by the library.
   gain=1 preserves encoded level. Render only after successful decode. */
STHDStatus sthd_render(const STHDFrame *frame, const STHDLayout *layout, float gain,
                       float *interleaved, size_t capacity);
STHDStatus sthd_layout_named(const char *name, STHDLayout *layout);
const char *sthd_speaker_name(STHDSpeaker speaker);
/* WAVE mask is zero for layouts with WAVE-unrepresentable wide/middle channels.
   Labels remain available in STHDLayout and the CLI sidecar. */
uint32_t sthd_wave_channel_mask(const STHDLayout *layout);
/* Read actual default-device labels. Unknown/discrete labels are returned as an
   error instead of inventing height speakers from a channel count. */
STHDStatus sthd_default_device_layout(STHDLayout *layout, char *description,
                                      size_t description_capacity);

/* Borrowed views retain the bitstream's distinction between channel PCM and
   positional feeds. View pointers are valid while the source frame is alive. */
typedef enum STHDPresentationKind {
    STHD_PRESENTATION_STEREO,
    STHD_PRESENTATION_51,
    STHD_PRESENTATION_71,
    STHD_PRESENTATION_IMMERSIVE
} STHDPresentationKind;
typedef struct STHDAudioObject {
    uint32_t id, sample_stride;
    STHDPosition position;
    const int32_t *pcm;
} STHDAudioObject;
typedef struct STHDDecodedPresentation {
    uint32_t samples, sample_rate, bed_sample_stride;
    STHDLayout bed_layout;
    const int32_t *bed_pcm;
    uint32_t object_count;
    STHDAudioObject objects[STHD_MAX_CHANNELS - 1];
} STHDDecodedPresentation;
STHDStatus sthd_presentation(const STHDFrame *frame, STHDPresentationKind kind,
                             STHDDecodedPresentation *view);

typedef enum STHDAudioBackend {
    STHD_AUDIO_NONE,
    STHD_AUDIO_COREAUDIO,
    STHD_AUDIO_WASAPI,
    STHD_AUDIO_WINDOWS_SPATIAL,
    STHD_AUDIO_PIPEWIRE,
    STHD_AUDIO_ALSA
} STHDAudioBackend;
typedef enum STHDAudioMode {
    STHD_AUDIO_PCM,
    STHD_AUDIO_STATIC_OBJECTS,
    STHD_AUDIO_POSITIONAL_OBJECTS
} STHDAudioMode;
typedef struct STHDAudioCapabilities {
    STHDAudioBackend pcm_backend;
    uint32_t pcm_available, pcm_layout_valid, pcm_channels, pcm_sample_rate;
    STHDLayout pcm_layout;
    /* Spatial positions describe the OS renderer's object inputs, not the
       physical speaker count. Each bit corresponds to an STHDSpeaker value. */
    uint32_t spatial_available, spatial_speaker_mask, max_dynamic_objects;
    uint32_t native_device_id;
    char endpoint[256];
} STHDAudioCapabilities;
typedef struct STHDAudioPlan {
    STHDAudioBackend backend;
    STHDAudioMode mode;
    STHDPresentationKind presentation;
    STHDLayout layout;
    uint32_t object_count, native_device_id;
    /* Normalized OAMD room coordinates become listener-relative meters.
       Defaults are one meter per axis; hosts may supply measured room extents. */
    float room_half_width_m, room_half_depth_m, room_height_m;
    char endpoint[256];
} STHDAudioPlan;
typedef struct STHDAudioOutput STHDAudioOutput;
/* Queries capabilities without starting playback. Unknown/discrete PCM labels
   remain unknown even when a known object-renderer mask is available. */
STHDStatus sthd_audio_capabilities(STHDAudioCapabilities *capabilities);
/* Ordinary channel presentations always choose the native PCM path. Immersive
   Windows feeds prefer positional objects, then native static objects. A PCM
   fallback requires allow_pcm_fallback=1. An explicit layout resolves unknown
   discrete labels only when the hardware channel count agrees. */
STHDStatus sthd_audio_plan(const STHDFrame *frame, const STHDAudioCapabilities *capabilities,
                           const STHDLayout *explicit_pcm_layout, int allow_pcm_fallback,
                           STHDAudioPlan *plan);
STHDAudioOutput *sthd_audio_open(const STHDAudioPlan *plan, char *error, size_t error_capacity);
/* Single producer; native backend consumes a bounded queue. Timeout permits
   hosts to cancel or report device loss. Playback gain is explicit. */
STHDStatus sthd_audio_write(STHDAudioOutput *output, const STHDFrame *frame, float gain,
                            uint32_t timeout_ms);
STHDStatus sthd_audio_drain(STHDAudioOutput *output, uint32_t timeout_ms);
typedef struct STHDAudioStats {
    uint64_t submitted_frames, consumed_frames, underruns;
    uint32_t queue_capacity_frames;
} STHDAudioStats;
STHDStatus sthd_audio_stats(const STHDAudioOutput *output, STHDAudioStats *stats);
uint64_t sthd_audio_underruns(const STHDAudioOutput *output);
const char *sthd_audio_error(const STHDAudioOutput *output);
void sthd_audio_close(STHDAudioOutput *output);
const char *sthd_audio_backend_name(STHDAudioBackend backend);

#ifdef __cplusplus
}
#endif
#endif
