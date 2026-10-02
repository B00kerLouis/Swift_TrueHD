// SPDX-License-Identifier: AGPL-3.0-only
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
// Single decoder producer, single native render consumer. Callback side never
// allocates, locks, decodes, performs file I/O, or calls the renderer.
struct Ring {
    static constexpr size_t capacity = 16384;
    const unsigned channels;
    std::vector<float> data;
    std::atomic<uint64_t> read{0}, write{0}, underruns{0};
    std::atomic<bool> stopping{false}, draining{false}, started{false};
    std::atomic<STHDStatus> failure{STHD_OK};
    std::array<STHDPosition, 16> positions{};
    std::atomic<bool> positions_ready{false};
    explicit Ring(unsigned c) : channels(c), data(capacity * c) {}
    size_t available() const {
        return size_t(write.load(std::memory_order_acquire) - read.load(std::memory_order_acquire));
    }
    bool push(const float *pcm, unsigned frames) {
        uint64_t w = write.load(std::memory_order_relaxed),
                 r = read.load(std::memory_order_acquire);
        if (w - r + frames > capacity)
            return false;
        for (unsigned i = 0; i < frames; ++i)
            std::copy_n(pcm + size_t(i) * channels, channels,
                        data.data() + size_t((w + i) % capacity) * channels);
        write.store(w + frames, std::memory_order_release);
        return true;
    }
    unsigned pop(float *pcm, unsigned frames) {
        uint64_t r = read.load(std::memory_order_relaxed),
                 w = write.load(std::memory_order_acquire);
        unsigned n = unsigned(std::min<uint64_t>(w - r, frames));
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
