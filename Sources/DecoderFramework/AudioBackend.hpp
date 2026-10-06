// SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once
#include "include/TrueHDDecoder.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <memory>
#include <thread>
#include <vector>
namespace sthd_audio {
// Validate the speaker positions reported by an OS without changing their
// physical order. Count, duplicate labels or unnamed discrete ports cannot
// establish a speaker geometry. All supported floor/height layouts use this.
inline bool reported_layout_valid(const STHDLayout &layout) {
    if (layout.channels < 2 || layout.channels > 16)
        return false;
    uint32_t seen = 0;
    for (unsigned i = 0; i < layout.channels; ++i) {
        unsigned s = unsigned(layout.speakers[i]);
        if (s >= 16 || (seen & (1U << s)))
            return false;
        seen |= 1U << s;
    }
    const char *names[] = {"2.0",   "5.1",   "7.1",   "5.1.2",     "5.1.4",       "7.1.2",
                           "7.1.4", "7.1.6", "9.1.6", "5.1(back)", "5.1.2(back)", "5.1.4(back)"};
    for (auto name : names) {
        STHDLayout supported{};
        sthd_layout_named(name, &supported);
        uint32_t mask = 0;
        for (unsigned i = 0; i < supported.channels; ++i)
            mask |= 1U << unsigned(supported.speakers[i]);
        if (mask == seen && supported.channels == layout.channels)
            return true;
    }
    return false;
}
// WAVE speaker masks explicitly define ascending physical slot order. Zero
// or an unsupported bit is unknown, even for a two-channel endpoint.
inline bool wave_mask_layout(uint32_t channels, uint32_t mask, STHDLayout &out) {
    const uint32_t bits[] = {1, 2, 4, 8, 16, 32, 512, 1024, 4096, 16384, 32768, 131072};
    STHDLayout value{};
    for (unsigned bit = 0; bit < 32; ++bit)
        if (mask & (1U << bit)) {
            bool known = false;
            for (unsigned s = 0; s < 12; ++s)
                if (bits[s] == (1U << bit)) {
                    if (value.channels >= 16)
                        return false;
                    value.speakers[value.channels++] = STHDSpeaker(s);
                    known = true;
                    break;
                }
            if (!known)
                return false;
        }
    if (value.channels != channels || !reported_layout_valid(value))
        return false;
    out = value;
    return true;
}
// An explicit device stereo preference is authoritative even when channel
// descriptions are Unknown. Never infer multichannel geometry from a count.
inline bool preferred_stereo_layout(uint32_t channels, uint32_t left, uint32_t right,
                                    STHDLayout &layout) {
    if (channels != 2 || left < 1 || left > 2 || right < 1 || right > 2 || left == right)
        return false;
    layout = STHDLayout{};
    layout.channels = 2;
    layout.speakers[left - 1] = STHD_FL;
    layout.speakers[right - 1] = STHD_FR;
    return true;
}

// Single decoder producer, single native render consumer. Callback side never
// allocates, locks, decodes, performs file I/O, or calls the renderer.
struct Ring {
    static constexpr size_t capacity = 16384;
    const unsigned channels;
    std::vector<float> data;
    std::atomic<uint64_t> read{0}, write{0}, underruns{0};
    std::atomic<bool> stopping{false}, draining{false}, started{false};
    std::atomic<STHDStatus> failure{STHD_OK};
    std::vector<STHDPosition> position_data;
    explicit Ring(unsigned c, bool positional = false)
        : channels(c), data(capacity * c), position_data(positional ? capacity * c : 0) {}
    size_t available() const {
        return size_t(write.load(std::memory_order_acquire) - read.load(std::memory_order_acquire));
    }
    bool push(const float *pcm, unsigned frames, const STHDFrameMotion *motion = nullptr,
              const STHDPosition *positions = nullptr) {
        uint64_t w = write.load(std::memory_order_relaxed),
                 r = read.load(std::memory_order_acquire);
        if (w - r + frames > capacity)
            return false;
        for (unsigned i = 0; i < frames; ++i) {
            std::copy_n(pcm + size_t(i) * channels, channels,
                        data.data() + size_t((w + i) % capacity) * channels);
            if (!position_data.empty())
                std::copy_n(motion ? motion->positions[i] : positions, channels,
                            position_data.data() + size_t((w + i) % capacity) * channels);
        }
        write.store(w + frames, std::memory_order_release);
        return true;
    }
    unsigned pop(float *pcm, unsigned frames, STHDPosition *first_positions = nullptr) {
        uint64_t r = read.load(std::memory_order_relaxed),
                 w = write.load(std::memory_order_acquire);
        unsigned n = unsigned(std::min<uint64_t>(w - r, frames));
        if (n && first_positions && !position_data.empty())
            std::copy_n(position_data.data() + size_t(r % capacity) * channels, channels,
                        first_positions);
        for (unsigned i = 0; i < n; ++i)
            std::copy_n(data.data() + size_t((r + i) % capacity) * channels, channels,
                        pcm + size_t(i) * channels);
        read.store(r + n, std::memory_order_release);
        return n;
    }
    void consume(float *pcm, unsigned frames) {
        unsigned n = pop(pcm, frames);
        std::fill(pcm + size_t(n) * channels, pcm + size_t(frames) * channels, 0.f);
        if (n < frames && !draining.load())
            underruns.fetch_add(1, std::memory_order_relaxed);
    }
};
struct Driver {
    Ring &ring;
    const STHDAudioPlan plan;
    char error[256]{};
    Driver(Ring &r, const STHDAudioPlan &p) : ring(r), plan(p) {}
    virtual ~Driver() = default;
    virtual STHDStatus open() = 0;
    virtual STHDStatus start() = 0;
    virtual STHDStatus finish(uint32_t timeout_ms) = 0;
};
#if defined(__APPLE__)
bool coreaudio_reported_labels(const uint32_t *labels, uint32_t channels, bool bitmap,
                               STHDLayout &layout);
#endif
std::unique_ptr<Driver> make_native(Ring &, const STHDAudioPlan &);
void native_capabilities(STHDAudioCapabilities &);
#if defined(STHD_HAVE_PIPEWIRE) && !defined(STHD_DISABLE_NATIVE_DEVICE)
STHDStatus pipewire_capabilities(STHDAudioCapabilities &);
std::unique_ptr<Driver> make_pipewire(Ring &, const STHDAudioPlan &);
#endif
inline bool wait_empty(Ring &r, uint32_t timeout_ms) {
    auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    while (r.available()) {
        if (r.failure.load() != STHD_OK || r.stopping.load() ||
            std::chrono::steady_clock::now() >= end)
            return false;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return true;
}
} // namespace sthd_audio
