// SPDX-License-Identifier: LGPL-2.1-or-later
#include "include/TrueHDDecoder.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <new>

struct STHDPlayer {
    STHDPlayerOptions options{};
    std::unique_ptr<STHDDecoder, decltype(&sthd_decoder_destroy)> decoder{nullptr,
                                                                          sthd_decoder_destroy};
    std::unique_ptr<STHDAudioOutput, decltype(&sthd_audio_close)> audio{nullptr, sthd_audio_close};
    // Protect only output-pointer publication/lifetime against concurrent
    // cancel. No lock is held while decoding, waiting, or native callbacks run.
    std::mutex output_mutex;
    std::atomic<bool> cancelled{false};
    std::array<uint8_t, STHD_MAX_ACCESS_UNIT> buffer{};
    size_t buffered = 0, expected = 4;
    STHDFrame frame{};
    STHDFrameMotion motion{};
    STHDAudioPlan plan{};
    STHDPlayerStats stats{};
    STHDStatus failure = STHD_OK;
    bool pending = false, end_marker = false, finished = false;
    char error[256]{};

    STHDStatus fail(STHDStatus status, const char *detail) {
        failure = status;
        std::snprintf(error, sizeof(error), "%s", detail);
        return status;
    }
    STHDStatus check_cancel() {
        if (!cancelled.load())
            return STHD_OK;
        std::lock_guard<std::mutex> lock(output_mutex);
        if (audio) {
            sthd_audio_stats(audio.get(), &stats.audio);
            audio.reset();
        }
        return fail(STHD_CANCELLED, "playback cancelled");
    }
    STHDStatus open_output() {
        STHDAudioCapabilities caps{};
        auto result = sthd_audio_capabilities(&caps);
        if (result != STHD_OK)
            return fail(result, caps.endpoint[0] ? caps.endpoint : sthd_status_string(result));
        result = sthd_audio_plan(&frame, &caps, options.explicit_layout ? &options.layout : nullptr,
                                 options.allow_pcm_fallback, &plan);
        if (result != STHD_OK)
            return fail(result, result == STHD_UNKNOWN_LAYOUT
                                    ? "device labels are unknown; supply an explicit layout"
                                    : sthd_status_string(result));
        char message[256]{};
        auto *output = sthd_audio_open(&plan, message, sizeof(message));
        if (!output)
            return fail(STHD_AUDIO_FAILURE, message);
        {
            std::lock_guard<std::mutex> lock(output_mutex);
            audio.reset(output);
            if (cancelled.load())
                sthd_audio_cancel(output);
        }
        stats.backend = plan.backend;
        stats.mode = plan.mode;
        stats.output_channels = plan.mode == STHD_AUDIO_POSITIONAL_OBJECTS ? plan.object_count + 1
                                                                           : plan.layout.channels;
        return check_cancel();
    }
    STHDStatus enqueue(uint32_t timeout) {
        if (!pending)
            return STHD_OK;
        auto result = check_cancel();
        if (result != STHD_OK)
            return result;
        if (!audio) {
            result = open_output();
            if (result != STHD_OK)
                return result;
        }
        result = sthd_audio_write_motion(audio.get(), &frame, &motion, options.gain, timeout);
        if (result == STHD_TIMEOUT) {
            std::snprintf(error, sizeof(error), "playback backpressure; retry pending frame");
            return result;
        }
        if (result == STHD_CANCELLED || cancelled.load())
            return check_cancel();
        if (result != STHD_OK)
            return fail(result, sthd_audio_error(audio.get()));
        pending = false;
        error[0] = 0;
        return STHD_OK;
    }
};
namespace {
uint32_t remaining(std::chrono::steady_clock::time_point deadline) {
    auto now = std::chrono::steady_clock::now();
    if (now >= deadline)
        return 0;
    return uint32_t(std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count());
}
} // namespace
extern "C" {
uint32_t sthd_abi_version(void) { return STHD_ABI_VERSION; }
STHDPlayer *sthd_player_create(const STHDPlayerOptions *o, char *error, size_t capacity) try {
    if (!error || !capacity)
        return nullptr;
    error[0] = 0;
    if (!o || o->struct_size != sizeof(STHDPlayerOptions) || !std::isfinite(o->gain) ||
        o->gain < 0) {
        std::snprintf(error, capacity, "invalid player options");
        return nullptr;
    }
    if (o->explicit_layout) {
        const char *names[] = {"2.0",   "5.1",       "7.1",         "5.1.2",
                               "5.1.4", "7.1.2",     "7.1.4",       "7.1.6",
                               "9.1.6", "5.1(back)", "5.1.2(back)", "5.1.4(back)"};
        bool valid = false;
        unsigned mask = 0;
        if (o->layout.channels > 16)
            return nullptr;
        for (unsigned i = 0; i < o->layout.channels; ++i) {
            unsigned s = unsigned(o->layout.speakers[i]);
            if (s >= 16 || (mask & (1U << s)))
                return nullptr;
            mask |= 1U << s;
        }
        for (auto name : names) {
            STHDLayout l{};
            sthd_layout_named(name, &l);
            unsigned m = 0;
            for (unsigned i = 0; i < l.channels; ++i)
                m |= 1U << unsigned(l.speakers[i]);
            if (m == mask && l.channels == o->layout.channels)
                valid = true;
        }
        if (!valid) {
            std::snprintf(error, capacity, "invalid explicit speaker layout");
            return nullptr;
        }
    }
    auto p = std::make_unique<STHDPlayer>();
    p->options = *o;
    p->decoder.reset(sthd_decoder_create());
    if (!p->decoder) {
        std::snprintf(error, capacity, "out of memory");
        return nullptr;
    }
    return p.release();
} catch (...) {
    if (error && capacity)
        std::snprintf(error, capacity, "cannot create player");
    return nullptr;
}
STHDStatus sthd_player_feed(STHDPlayer *p, const uint8_t *data, size_t bytes, size_t *consumed,
                            uint32_t timeout) try {
    if (consumed)
        *consumed = 0;
    if (!p || !consumed || (!data && bytes))
        return STHD_INVALID_ARGUMENT;
    if (p->check_cancel() != STHD_OK)
        return STHD_CANCELLED;
    if (p->failure != STHD_OK)
        return p->failure;
    if (p->finished)
        return STHD_INVALID_ARGUMENT;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout);
    while (true) {
        auto result = p->enqueue(remaining(deadline));
        if (result != STHD_OK)
            return result;
        if (p->check_cancel() != STHD_OK)
            return STHD_CANCELLED;
        if (p->buffered == p->expected) {
            if (p->expected == 4) {
                p->expected = ((unsigned(p->buffer[0]) & 15) * 256 + p->buffer[1]) * 2;
                if (p->expected < 4 || p->expected > p->buffer.size())
                    return p->fail(STHD_CORRUPT_STREAM, "invalid streaming AU length");
            }
            if (p->buffered == p->expected) {
                result = sthd_decode_access_unit(p->decoder.get(), p->buffer.data(), p->expected,
                                                 &p->frame);
                if (result != STHD_OK)
                    return p->fail(result, sthd_decoder_error(p->decoder.get()));
                result = sthd_decoder_motion(p->decoder.get(), &p->motion);
                if (result != STHD_OK)
                    return p->fail(result, "decoded motion unavailable");
                p->buffered = 0;
                p->expected = 4;
                p->pending = true;
                p->end_marker = sthd_decoder_end_of_stream(p->decoder.get()) != 0;
                ++p->stats.decoded_access_units;
                p->stats.decoded_samples += p->frame.samples;
                continue;
            }
        }
        if (*consumed == bytes) {
            p->error[0] = 0;
            return STHD_OK;
        }
        if (p->end_marker)
            return p->fail(STHD_CORRUPT_STREAM, "data follows stream termination marker");
        size_t n = std::min(bytes - *consumed, p->expected - p->buffered);
        std::copy_n(data + *consumed, n, p->buffer.data() + p->buffered);
        p->buffered += n;
        *consumed += n;
        p->stats.accepted_bytes += n;
    }
} catch (const std::bad_alloc &) {
    return p ? p->fail(STHD_OUT_OF_MEMORY, "out of memory") : STHD_OUT_OF_MEMORY;
} catch (...) {
    return p ? p->fail(STHD_AUDIO_FAILURE, "streaming playback failed") : STHD_AUDIO_FAILURE;
}
STHDStatus sthd_player_finish(STHDPlayer *p, uint32_t timeout) try {
    if (!p)
        return STHD_INVALID_ARGUMENT;
    if (p->check_cancel() != STHD_OK)
        return STHD_CANCELLED;
    if (p->failure != STHD_OK)
        return p->failure;
    if (p->finished)
        return STHD_OK;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout);
    auto result = p->enqueue(remaining(deadline));
    if (result != STHD_OK)
        return result;
    if (p->buffered)
        return p->fail(STHD_CORRUPT_STREAM, "end of input inside an AU header/payload");
    if (!p->stats.decoded_access_units)
        return p->fail(STHD_CORRUPT_STREAM, "empty encoded stream");
    result = sthd_audio_drain(p->audio.get(), remaining(deadline));
    if (result == STHD_CANCELLED || p->cancelled.load())
        return p->check_cancel();
    if (result == STHD_TIMEOUT) {
        std::snprintf(p->error, sizeof(p->error), "native output drain timed out; retry finish");
        return result;
    }
    if (result != STHD_OK)
        return p->fail(result, sthd_audio_error(p->audio.get()));
    {
        std::lock_guard<std::mutex> lock(p->output_mutex);
        sthd_audio_stats(p->audio.get(), &p->stats.audio);
        p->audio.reset();
    }
    if (p->check_cancel() != STHD_OK)
        return STHD_CANCELLED;
    p->finished = true;
    p->error[0] = 0;
    return STHD_OK;
} catch (...) {
    return p ? p->fail(STHD_AUDIO_FAILURE, "streaming playback finish failed") : STHD_AUDIO_FAILURE;
}
STHDStatus sthd_player_stats(const STHDPlayer *p, STHDPlayerStats *s) {
    if (!p || !s)
        return STHD_INVALID_ARGUMENT;
    *s = p->stats;
    if (p->audio)
        sthd_audio_stats(p->audio.get(), &s->audio);
    s->buffered_bytes = p->buffered;
    s->pending_frame = p->pending;
    s->finished = p->finished;
    s->cancelled = p->cancelled.load();
    return STHD_OK;
}
STHDStatus sthd_player_last_frame(const STHDPlayer *p, STHDFrame *f) {
    if (!p || !f)
        return STHD_INVALID_ARGUMENT;
    if (!p->stats.decoded_access_units)
        return STHD_NEED_RESTART;
    *f = p->frame;
    return STHD_OK;
}
STHDStatus sthd_player_last_motion(const STHDPlayer *p, STHDFrameMotion *motion) {
    if (!p || !motion)
        return STHD_INVALID_ARGUMENT;
    if (!p->stats.decoded_access_units)
        return STHD_NEED_RESTART;
    *motion = p->motion;
    return STHD_OK;
}
STHDStatus sthd_player_pcm_checksum(const STHDPlayer *p, STHDPCMChecksum *checksum) {
    return p ? sthd_decoder_pcm_checksum(p->decoder.get(), checksum) : STHD_INVALID_ARGUMENT;
}
STHDStatus sthd_player_set_strict_pcm_checksum(STHDPlayer *p, int strict) {
    return p ? sthd_decoder_set_strict_pcm_checksum(p->decoder.get(), strict) : STHD_INVALID_ARGUMENT;
}
uint32_t sthd_player_end_of_stream(const STHDPlayer *p) { return p && p->end_marker; }
const char *sthd_player_error(const STHDPlayer *p) { return p ? p->error : "null player"; }
void sthd_player_cancel(STHDPlayer *p) {
    if (!p)
        return;
    p->cancelled.store(true);
    std::lock_guard<std::mutex> lock(p->output_mutex);
    if (p->audio)
        sthd_audio_cancel(p->audio.get());
}
void sthd_player_destroy(STHDPlayer *p) {
    if (p)
        sthd_player_cancel(p);
    delete p;
}
}
