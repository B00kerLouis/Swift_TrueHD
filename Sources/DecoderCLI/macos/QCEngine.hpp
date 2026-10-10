// Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once
#include "TrueHDDecoder.h"
#include <array>
#include <atomic>
#include <condition_variable>
#include <chrono>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

namespace sthd_qc {
enum class Monitor { direct, downmix, meters };
enum class LevelMode { playback, encoded };
struct Snapshot {
    std::string path, status = "Open TrueHD audio", device, layoutName = "7.1.4";
    STHDLayout layout{};
    uint64_t position = 0, total = 0, clips = 0, monitorClips = 0, checksumMismatches = 0;
    bool loaded = false, playing = false, seeking = false, immersive = false, scrubbing = false;
    bool coordinatesAvailable = true;
    uint64_t unavailableSamples = 0;
    uint32_t checkpointCount = 0;
    float presentationGainDB = 0;
    LevelMode levelMode = LevelMode::playback;
    uint64_t span = 0;
    std::chrono::steady_clock::time_point stamp = std::chrono::steady_clock::now();
    int solo = -1;
    std::array<float, 16> peak{}, rms{};
};
// Main-thread commands only publish intent. The worker owns file, decoder and
// audio lifetimes. Seeking restores a bounded checkpoint, then replays FIR/IIR
// and OAMD state to the requested sample.
class Engine {
public:
    Engine();
    ~Engine();
    void load(const std::string &path, bool autoplay = true);
    void toggle();
    void stop();
    void seek(uint64_t sample);
    void beginScrub();
    void previewScrub(uint64_t sample);
    void endScrub(uint64_t sample);
    void skip(double seconds);
    void layout(const std::string &name);
    void monitor(Monitor mode);
    void levels(LevelMode mode);
    void volume(float gain);
    void solo(int channel);
    Snapshot snapshot();
    void shutdown();
private:
    std::mutex mutex_;
    std::condition_variable changed_;
    Snapshot state_;
    std::array<double, 16> squares_{};
    uint64_t metered_ = 0;
    std::string requestedPath_;
    uint64_t requestedSample_ = 0;
    bool quitting_ = false, loadPending_ = false, seekPending_ = false;
    bool flushPending_ = false, resumeAfterScrub_ = false;
    Monitor monitor_ = Monitor::direct;
    float volume_ = 0.5f;
    std::atomic<uint64_t> generation_{0};
    std::thread worker_;
    void reconfigure(); // mutex_ held.
    void run();
};
struct RenderResult {
    unsigned presentation = 0;
    uint64_t availableSamples = 0;
    float gainDB = 0;
};
// GUI playback distinguishes encoded compatibility channels from immersive
// object feeds. Core PCM and the stateless public renderer remain unchanged.
RenderResult renderPCM(const STHDFrame &, const STHDFrameMotion &,
                       const STHDPlaybackLevels &, const STHDLayout &, LevelMode,
                       float *output, size_t capacity);
// Export uses an independent decoder and exclusively-created destination and
// sidecar. Cancellation removes newly-created incomplete outputs. No PCM cache.
enum class Format { wave, s24, s32, f32 };
struct ExportResult { uint64_t samples = 0, clips = 0, overRange = 0, checksumMismatches = 0; };
ExportResult exportPCM(const std::string &input, const std::string &output,
                       const std::string &layout, Format format, std::atomic<bool> &cancel,
                       const std::function<void(uint64_t)> &progress = {},
                       LevelMode levels = LevelMode::encoded);
} // namespace sthd_qc
