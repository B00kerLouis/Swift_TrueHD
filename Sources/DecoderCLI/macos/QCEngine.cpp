// Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later
#include "QCEngine.hpp"
#include "../PCMFile.hpp"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <fstream>
#include <memory>
#include <stdexcept>

namespace sthd_qc {
namespace {
using Clock = std::chrono::steady_clock;
void require(STHDStatus status) {
    if (status != STHD_OK) throw std::runtime_error(sthd_status_string(status));
}
// Each read retains one compressed AU and one decoded frame. No index grows
// with programme length. File errors and data following termination are fatal.
class Reader {
    std::ifstream input_;
    std::unique_ptr<STHDDecoder, decltype(&sthd_decoder_destroy)> decoder_;
    std::array<uint8_t, STHD_MAX_ACCESS_UNIT> bytes_{};
    using Decoder = std::unique_ptr<STHDDecoder, decltype(&sthd_decoder_destroy)>;
    struct Point {
        uint64_t byte = 0, sample = 0;
        Decoder decoder{nullptr, sthd_decoder_destroy};
    };
    std::array<Point, 128> points_{};
    unsigned pointCount_ = 0;
public:
    STHDFrame frame{};
    STHDFrameMotion motion{};
    explicit Reader(const std::string &path)
        : input_(std::filesystem::u8path(path), std::ios::binary),
          decoder_(sthd_decoder_create(), sthd_decoder_destroy) {
        if (!input_) throw std::runtime_error("Cannot open input: " + path);
        if (!decoder_) throw std::bad_alloc();
    }
    void reset() {
        input_.clear(); input_.seekg(0);
        if (!input_) throw std::runtime_error("Input seek failed");
        sthd_decoder_reset(decoder_.get());
    }
    bool next() {
        if (sthd_decoder_end_of_stream(decoder_.get())) {
            if (input_.peek() != EOF) throw std::runtime_error("Data follows stream termination");
            if (input_.bad()) throw std::runtime_error("Input read failed");
            return false;
        }
        input_.read(reinterpret_cast<char *>(bytes_.data()), 4);
        if (!input_.gcount() && input_.eof()) return false;
        if (input_.gcount() != 4) throw std::runtime_error("Truncated access header");
        const size_t size = ((unsigned(bytes_[0]) & 15) * 256 + bytes_[1]) * 2;
        if (size < 4 || size > bytes_.size()) throw std::runtime_error("Invalid access unit size");
        input_.read(reinterpret_cast<char *>(bytes_.data() + 4), std::streamsize(size - 4));
        if (size_t(input_.gcount()) != size - 4) throw std::runtime_error("Truncated access unit");
        auto status = sthd_decode_access_unit(decoder_.get(), bytes_.data(), size, &frame);
        if (status != STHD_OK)
            throw std::runtime_error(std::string(sthd_status_string(status)) + ": " +
                                     sthd_decoder_error(decoder_.get()));
        require(sthd_decoder_motion(decoder_.get(), &motion));
        return true;
    }
    unsigned checkpointCount() const { return pointCount_; }
    template<class Cancel> uint64_t prepare(Cancel cancelled) {
        reset(); pointCount_ = 0;
        points_[0].decoder.reset(sthd_decoder_clone(decoder_.get()));
        if (!points_[0].decoder) throw std::bad_alloc();
        points_[0].byte = points_[0].sample = 0; pointCount_ = 1;
        uint64_t stride = 24000, nextPoint = stride, total = 0;
        while (next()) {
            if (cancelled()) return 0;
            total += frame.samples;
            if (total >= nextPoint) {
                if (pointCount_ == points_.size()) {
                    for (unsigned i = 1; i < pointCount_ / 2; ++i)
                        points_[i] = std::move(points_[i * 2]);
                    for (unsigned i = pointCount_ / 2; i < pointCount_; ++i)
                        points_[i].decoder.reset();
                    pointCount_ /= 2; stride *= 2;
                }
                auto &p = points_[pointCount_++];
                p.byte = uint64_t(input_.tellg()); p.sample = total;
                p.decoder.reset(sthd_decoder_clone(decoder_.get()));
                if (!p.decoder) throw std::bad_alloc();
                nextPoint = total + stride;
            }
        }
        return total;
    }
    uint64_t restore(uint64_t sample) {
        unsigned i = pointCount_;
        while (i && points_[i-1].sample > sample) --i;
        if (!i) { reset(); return 0; }
        const auto &p = points_[i-1];
        Decoder copy(sthd_decoder_clone(p.decoder.get()), sthd_decoder_destroy);
        if (!copy) throw std::bad_alloc();
        input_.clear(); input_.seekg(std::streamoff(p.byte));
        if (!input_) throw std::runtime_error("Input checkpoint seek failed");
        decoder_ = std::move(copy); return p.sample;
    }
    STHDPlaybackLevels levels() const {
        STHDPlaybackLevels result{};
        require(sthd_decoder_playback_levels(decoder_.get(), &result));
        return result;
    }
    uint64_t mismatches() const {
        STHDPCMChecksum c{};
        require(sthd_decoder_pcm_checksum(decoder_.get(), &c));
        return c.total_mismatches;
    }
};
STHDLayout named(const std::string &name) {
    STHDLayout result{}; require(sthd_layout_named(name.c_str(), &result)); return result;
}
STHDLayout qcLayout(const std::string &name) {
    auto source = named(name); STHDLayout ordered{};
    static const STHDSpeaker display[] = {STHD_FL, STHD_FR, STHD_FC, STHD_LFE,
        STHD_SL, STHD_SR, STHD_BL, STHD_BR, STHD_FWL, STHD_FWR,
        STHD_TFL, STHD_TFR, STHD_TML, STHD_TMR, STHD_TBL, STHD_TBR};
    for (auto label : display) for (unsigned c = 0; c < source.channels; ++c)
        if (source.speakers[c] == label) ordered.speakers[ordered.channels++] = label;
    return ordered;
}
// Monitoring folds the virtual QC feeds, not the encoded compatibility layer.
// Exact positions have unity gain. Missing heights fold into their floor
// counterpart; missing surrounds/centre use explicit -3 dB folds. LFE stays LFE.
void fold(const STHDLayout &source, const STHDLayout &target, float matrix[16][16]) {
    constexpr float k = 0.7071067811865476f;
    auto index = [&](STHDSpeaker s) {
        for (unsigned o = 0; o < target.channels; ++o)
            if (target.speakers[o] == s) return int(o);
        return -1;
    };
    auto add = [&](unsigned c, STHDSpeaker s, float gain) {
        int o = index(s); if (o >= 0) matrix[o][c] += gain;
    };
    for (unsigned c = 0; c < source.channels; ++c) {
        auto s = source.speakers[c]; int o = index(s);
        if (o >= 0) { matrix[o][c] = 1; continue; }
        if (s == STHD_LFE) continue;
        if (s == STHD_FC) { add(c, STHD_FL, k); add(c, STHD_FR, k); continue; }
        bool left = s == STHD_FL || s == STHD_BL || s == STHD_SL ||
                    s == STHD_TFL || s == STHD_TBL || s == STHD_TML || s == STHD_FWL;
        auto front = left ? STHD_FL : STHD_FR;
        auto side = left ? STHD_SL : STHD_SR;
        auto rear = left ? STHD_BL : STHD_BR;
        auto topFront = left ? STHD_TFL : STHD_TFR;
        auto topRear = left ? STHD_TBL : STHD_TBR;
        auto topMiddle = left ? STHD_TML : STHD_TMR;
        if (s >= STHD_TFL && s <= STHD_TMR) {
            if (index(topMiddle) >= 0) { add(c, topMiddle, 1); continue; }
            if (s == topMiddle && index(topFront) >= 0 && index(topRear) >= 0) {
                add(c, topFront, k); add(c, topRear, k); continue;
            }
            auto same = s == topRear ? topRear : topFront;
            if (index(same) >= 0) { add(c, same, 1); continue; }
            s = s == topRear ? rear : (s == topMiddle ? side : front);
            if (index(s) >= 0) { add(c, s, k); continue; }
        }
        if (s == rear || s == side) {
            auto other = s == rear ? side : rear;
            if (index(other) >= 0) { add(c, other, k); continue; }
        }
        add(c, front, k);
    }
}
} // namespace

RenderResult renderPCM(const STHDFrame &frame, const STHDFrameMotion &motion,
                       const STHDPlaybackLevels &levels, const STHDLayout &layout,
                       LevelMode mode, float *output, size_t capacity) {
    if (capacity < size_t(frame.samples) * layout.channels)
        throw std::runtime_error("QC output buffer is too small");
    bool height = false;
    for (unsigned c = 0; c < layout.channels; ++c) height |= layout.speakers[c] >= STHD_TFL;
    unsigned layer = height ? (frame.presentations == 4 ? 3 : 2) :
                     (layout.channels == 2 ? 0 : layout.channels == 6 ? 1 : 2);
    const float gain = mode == LevelMode::playback ? levels.gain[layer] : 1;
    RenderResult result{layer, (uint64_t(1) << frame.samples) - 1,
                        mode == LevelMode::playback ? float(levels.dialnorm[layer]) - 31 : 0};
    if (!height) {
        // Compatibility PCM already carries the selected presentation's matrix.
        // Side/back WAVE order differs from the immersive renderer's object order.
        for (unsigned n = 0; n < frame.samples; ++n)
            for (unsigned c = 0; c < layout.channels; ++c) {
                unsigned source = unsigned(layout.speakers[c]);
                if (layer == 1 && source >= unsigned(STHD_SL)) source -= 2;
                output[n * layout.channels + c] = float(double(frame.pcm[layer][n * frame.channels[layer] + source]) * gain / 8388608);
            }
    } else if (frame.presentations == 4 && motion.valid_samples != result.availableSamples) {
        // Unknown ramp origins are not guessed. Keep playback's sample timeline
        // while explicitly marking spatial meters unavailable until coordinates
        // become valid. Native element export preserves these original samples.
        std::fill_n(output, frame.samples * layout.channels, 0);
        result.availableSamples = motion.valid_samples;
        STHDFrame sample = frame; sample.samples = 1; sample.positions_valid = 1;
        for (unsigned n = 0; n < frame.samples; ++n) if (motion.valid_samples & (uint64_t(1) << n)) {
            for (unsigned p = 0; p < frame.presentations; ++p)
                std::copy_n(frame.pcm[p] + n * frame.channels[p], frame.channels[p], sample.pcm[p]);
            std::copy_n(motion.positions[n], motion.channels, sample.positions);
            require(sthd_render(&sample, &layout, gain, output + n * layout.channels,
                                capacity - n * layout.channels));
        }
    } else require(sthd_render_motion(&frame, &motion, &layout, gain, output, capacity));
    return result;
}
namespace {
uint64_t displayed(const Snapshot &s) {
    if (!s.playing || s.seeking || s.scrubbing) return s.position;
    auto elapsed = std::max(0.0, std::chrono::duration<double>(Clock::now() - s.stamp).count());
    return std::min(s.total, s.position + std::min(s.span, uint64_t(elapsed * 48000)));
}
}

Engine::Engine() {
    state_.layout = qcLayout(state_.layoutName);
    worker_ = std::thread(&Engine::run, this);
}
Engine::~Engine() { shutdown(); }
void Engine::shutdown() {
    { std::lock_guard<std::mutex> lock(mutex_); quitting_ = true; ++generation_; changed_.notify_all(); }
    if (worker_.joinable()) worker_.join();
}
void Engine::load(const std::string &path, bool autoplay) {
    std::lock_guard<std::mutex> lock(mutex_);
    requestedPath_ = path; loadPending_ = true; seekPending_ = false;
    state_.loaded = false; state_.playing = autoplay; state_.seeking = true;
    state_.scrubbing = false; resumeAfterScrub_ = false; state_.span = 0;
    state_.status = "Measuring and validating audio…";
    ++generation_; changed_.notify_all();
}
void Engine::toggle() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!state_.loaded) return;
    const auto position = displayed(state_);
    state_.playing = !state_.playing;
    state_.position = position; state_.span = 0;
    requestedSample_ = position >= state_.total ? 0 : position;
    seekPending_ = true; state_.seeking = true;
    ++generation_; changed_.notify_all();
}
void Engine::seek(uint64_t sample) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!state_.loaded) return;
    requestedSample_ = std::min(sample, state_.total);
    state_.position = requestedSample_; state_.seeking = true; seekPending_ = true;
    state_.status = "Seeking (replaying stream state)…";
    ++generation_; changed_.notify_all();
}
void Engine::stop() {
    { std::lock_guard<std::mutex> lock(mutex_); state_.playing = false; }
    seek(0);
}
void Engine::skip(double seconds) {
    auto s = snapshot();
    seek(uint64_t(std::max(0.0, double(s.position) + seconds * 48000)));
}
void Engine::layout(const std::string &name) {
    auto l = qcLayout(name);
    std::lock_guard<std::mutex> lock(mutex_);
    state_.layout = l; state_.layoutName = name; state_.solo = -1;
    state_.peak = {}; squares_ = {}; metered_ = 0;
    reconfigure(); changed_.notify_all();
}
void Engine::monitor(Monitor mode) {
    std::lock_guard<std::mutex> lock(mutex_);
    monitor_ = mode;
    reconfigure(); changed_.notify_all();
}
void Engine::reconfigure() {
    if (!state_.loaded || !state_.playing || state_.scrubbing) return;
    requestedSample_ = displayed(state_); state_.position = requestedSample_; state_.span = 0;
    seekPending_ = true; state_.seeking = true; ++generation_;
}
void Engine::levels(LevelMode mode) {
    std::lock_guard<std::mutex> lock(mutex_);
    state_.levelMode = mode; reconfigure(); changed_.notify_all();
}
void Engine::beginScrub() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!state_.loaded || state_.scrubbing) return;
    state_.position = displayed(state_); state_.span = 0;
    resumeAfterScrub_ = state_.playing; state_.playing = false; state_.scrubbing = true;
    state_.seeking = false; seekPending_ = false; flushPending_ = true;
    state_.peak = {}; squares_ = {}; metered_ = 0;
    state_.status = "Scrubbing"; ++generation_; changed_.notify_all();
}
void Engine::previewScrub(uint64_t sample) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (state_.scrubbing) state_.position = std::min(sample, state_.total);
}
void Engine::endScrub(uint64_t sample) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!state_.scrubbing) return;
    state_.scrubbing = false; state_.playing = resumeAfterScrub_; resumeAfterScrub_ = false;
    requestedSample_ = std::min(sample, state_.total); state_.position = requestedSample_;
    state_.seeking = true; seekPending_ = true; ++generation_; changed_.notify_all();
}
void Engine::volume(float gain) {
    std::lock_guard<std::mutex> lock(mutex_);
    volume_ = std::clamp(gain, 0.0f, 1.0f);
}
void Engine::solo(int channel) {
    std::lock_guard<std::mutex> lock(mutex_);
    state_.solo = state_.solo == channel ? -1 :
                  (channel >= 0 && channel < int(state_.layout.channels) ? channel : -1);
    reconfigure(); changed_.notify_all();
}
Snapshot Engine::snapshot() {
    std::lock_guard<std::mutex> lock(mutex_);
    auto s = state_; s.position = displayed(s); s.span = 0;
    for (unsigned c = 0; c < s.layout.channels; ++c)
        s.rms[c] = metered_ ? float(std::sqrt(squares_[c] / metered_)) : 0;
    state_.peak = {}; squares_ = {}; metered_ = 0;
    return s;
}
void Engine::run() {
    std::unique_ptr<Reader> reader;
    std::unique_ptr<STHDAudioOutput, decltype(&sthd_audio_close)> audio(nullptr, sthd_audio_close);
    STHDAudioCapabilities caps{};
    uint64_t cursor = 0, audioGeneration = UINT64_MAX;
    unsigned first = 0;
    bool pending = false;
    auto deadline = Clock::now();
    uint64_t scheduled = 0, scheduleGeneration = UINT64_MAX;
    while (true) {
        std::unique_lock<std::mutex> lock(mutex_);
        changed_.wait(lock, [&] { return quitting_ || loadPending_ || flushPending_ || seekPending_ ||
                                         (state_.playing && reader && state_.loaded); });
        if (quitting_) break;
        const uint64_t gen = generation_;
        try {
            if (scheduleGeneration != gen) {
                scheduled = 0; deadline = Clock::now(); scheduleGeneration = gen;
            }
            if (flushPending_) {
                flushPending_ = false; lock.unlock(); audio.reset(); lock.lock();
                if (generation_ != gen) continue;
            }
            if (loadPending_) {
                auto path = requestedPath_; loadPending_ = false;
                lock.unlock(); audio.reset(); reader = std::make_unique<Reader>(path);
                uint64_t total = reader->prepare([&] { return generation_ != gen; });
                bool immersive = reader->frame.presentations == 4;
                if (generation_ != gen) continue;
                if (!total) throw std::runtime_error("Input contains no audio");
                auto checks = reader->mismatches(); reader->reset(); cursor = 0; pending = false;
                lock.lock();
                if (generation_ != gen) continue;
                state_.path = path; state_.total = total; state_.position = 0;
                state_.loaded = true; state_.seeking = false; state_.immersive = immersive;
                state_.clips = state_.monitorClips = state_.unavailableSamples = 0;
                state_.checkpointCount = reader->checkpointCount(); state_.checksumMismatches = checks;
                state_.status = "Ready"; deadline = Clock::now();
            }
            if (seekPending_) {
                auto wanted = requestedSample_; seekPending_ = false;
                lock.unlock(); audio.reset(); cursor = reader->restore(wanted); pending = false;
                while (reader->next()) {
                    const unsigned n = reader->frame.samples;
                    if (cursor + n > wanted) { first = unsigned(wanted - cursor); pending = true; cursor = wanted; break; }
                    cursor += n;
                    if (generation_ != gen) break;
                }
                if (generation_ != gen) continue;
                lock.lock();
                if (generation_ != gen) continue;
                state_.position = cursor; state_.seeking = false;
                state_.peak = {}; squares_ = {}; metered_ = 0;
                state_.status = state_.playing ? "Playing" : "Paused"; deadline = Clock::now();
            }
            if (!state_.playing) { lock.unlock(); audio.reset(); continue; }
            auto layout = state_.layout; auto mode = monitor_; int solo = state_.solo; float volume = volume_;
            auto levelMode = state_.levelMode;
            lock.unlock();
            if (audioGeneration != gen) { audio.reset(); audioGeneration = gen; }
            if (!pending) {
                if (!reader->next()) {
                    if (audio) {
                        auto status = sthd_audio_drain(audio.get(), 100);
                        while (status == STHD_TIMEOUT && generation_ == gen)
                            status = sthd_audio_drain(audio.get(), 100);
                        if (generation_ != gen) continue;
                        require(status);
                    }
                    audio.reset(); lock.lock(); state_.playing = false; state_.position = state_.total;
                    state_.status = "End of programme"; continue;
                }
                first = 0;
            }
            pending = false;
            const auto &frame = reader->frame;
            std::array<float, 640> qc{}, physical{};
            const auto render = renderPCM(frame, reader->motion, reader->levels(), layout,
                                          levelMode, qc.data(), qc.size());
            const unsigned count = frame.samples - first;
            uint64_t clips = 0, outputClips = 0;
            std::array<float, 16> peaks{};
            std::array<double, 16> squares{};
            for (unsigned n = first; n < frame.samples; ++n)
                for (unsigned c = 0; c < layout.channels; ++c) {
                    float v = qc[n * layout.channels + c];
                    peaks[c] = std::max(peaks[c], std::abs(v)); squares[c] += double(v) * v;
                    clips += v > 8388607.0 / 8388608 || v < -1;
                }
            std::string device = "QC meters only";
            if (mode != Monitor::meters) {
                if (!audio) {
                    require(sthd_audio_capabilities(&caps));
                    if (!caps.pcm_layout_valid) throw std::runtime_error("Device has unknown channel labels; use QC Meters Only");
                    STHDAudioPlan plan{};
                    plan.backend = caps.pcm_backend; plan.mode = STHD_AUDIO_PCM;
                    plan.layout = caps.pcm_layout; plan.native_device_id = caps.native_device_id;
                    std::copy_n(caps.endpoint, sizeof(plan.endpoint), plan.endpoint);
                    char error[256]{}; audio.reset(sthd_audio_open(&plan, error, sizeof(error)));
                    if (!audio) throw std::runtime_error(error);
                }
                device = std::string(caps.endpoint) + " · " + std::to_string(caps.pcm_layout.channels) + " ch";
                float matrix[16][16]{};
                if (mode == Monitor::downmix) fold(layout, caps.pcm_layout, matrix);
                for (unsigned o = 0; o < caps.pcm_layout.channels; ++o)
                    for (unsigned n = 0; n < count; ++n) {
                        double value = 0;
                        if (solo >= 0) {
                            if (caps.pcm_layout.speakers[o] == STHD_FL || caps.pcm_layout.speakers[o] == STHD_FR)
                                value = qc[(n + first) * layout.channels + unsigned(solo)] * 0.7071067811865476;
                        } else {
                            for (unsigned c = 0; c < layout.channels; ++c)
                                value += qc[(n + first) * layout.channels + c] *
                                    (mode == Monitor::direct ? float(layout.speakers[c] == caps.pcm_layout.speakers[o]) : matrix[o][c]);
                        }
                        value *= volume; outputClips += value > 8388607.0 / 8388608 || value < -1;
                        physical[n * caps.pcm_layout.channels + o] = float(std::clamp(value, -1.0, 8388607.0 / 8388608));
                    }
                auto status = sthd_audio_write_pcm(audio.get(), physical.data(), count, physical.size(), 20);
                while (status == STHD_TIMEOUT && generation_ == gen)
                    status = sthd_audio_write_pcm(audio.get(), physical.data(), count, physical.size(), 20);
                if (generation_ != gen) continue;
                require(status);
            }
            cursor += count;
            lock.lock();
            if (generation_ != gen) continue;
            state_.position = cursor; state_.span = 0;
            state_.coordinatesAvailable = render.availableSamples == ((uint64_t(1) << frame.samples) - 1);
            state_.presentationGainDB = render.gainDB;
            uint64_t available = render.availableSamples;
            for (unsigned n = first; n < frame.samples; ++n)
                state_.unavailableSamples += !(available & (uint64_t(1) << n));
            state_.status = state_.coordinatesAvailable ? "Playing" : "Object coordinates unavailable";
            state_.device = device;
            state_.clips += clips; state_.monitorClips += outputClips; metered_ += count;
            for (unsigned c = 0; c < layout.channels; ++c) {
                state_.peak[c] = std::max(state_.peak[c], peaks[c]); squares_[c] += squares[c];
            }
            scheduled += count;
            if (scheduled >= 1600) {
                const auto span = scheduled; scheduled = 0;
                state_.position = cursor - span; state_.span = span; state_.stamp = Clock::now();
                deadline += std::chrono::duration_cast<Clock::duration>(std::chrono::duration<double>(double(span) / 48000));
                if (deadline < Clock::now() - std::chrono::milliseconds(100)) deadline = Clock::now();
                changed_.wait_until(lock, deadline, [&] { return quitting_ || generation_ != gen; });
                if (generation_ == gen) { state_.position = cursor; state_.span = 0; }
            }
        } catch (const std::exception &e) {
            if (lock.owns_lock()) lock.unlock();
            audio.reset();
            lock.lock();
            if (generation_ == gen) {
                state_.playing = false; state_.seeking = false; state_.status = e.what();
            }
        }
    }
}

ExportResult exportPCM(const std::string &input, const std::string &output,
                       const std::string &name, Format format, std::atomic<bool> &cancel,
                       const std::function<void(uint64_t)> &progress, LevelMode levelMode) {
    Reader reader(input);
    const bool native = name == "elements";
    STHDLayout layout = native ? STHDLayout{} : qcLayout(name);
    const STHDLayout nativeLayout = named("7.1");
    std::unique_ptr<sthd_cli::Wave> wave;
    std::unique_ptr<sthd_cli::File> sidecar;
    ExportResult result{};
    unsigned channels = 0;
    bool update = false;
    while (true) {
        if (cancel) throw std::runtime_error("Export cancelled");
        if (!reader.next()) break;
        const auto &frame = reader.frame;
        unsigned layer = frame.presentations == 4 ? 3 : 2;
        if (!wave) {
            channels = native ? frame.channels[layer] : layout.channels;
            sidecar = std::make_unique<sthd_cli::File>(std::filesystem::u8path(output + ".channels.json"));
            wave = std::make_unique<sthd_cli::Wave>(std::filesystem::u8path(output), channels,
                        native && layer == 3 ? 0 : sthd_wave_channel_mask(native ? &nativeLayout : &layout),
                        format != Format::wave);
            const std::string start = "{\n  \"sampleRate\": 48000,\n  \"drcApplied\": false,\n  \"channels\": [";
            sidecar->write(start.data(), start.size());
            for (unsigned c = 0; c < channels; ++c) {
                std::string label = native && layer == 3 ? "element-" + std::to_string(c) :
                    sthd_speaker_name(native ? named("7.1").speakers[c] : layout.speakers[c]);
                std::string entry = (c ? ", " : "") + std::string("\"") + label + "\"";
                sidecar->write(entry.data(), entry.size());
            }
            const std::string end = "],\n  \"positionUpdates\": [\n"; sidecar->write(end.data(), end.size());
        }
        std::array<float, 640> rendered{};
        std::array<int32_t, 640> pcm{};
        if (native) std::copy_n(frame.pcm[layer], frame.samples * channels, pcm.data());
        else {
            auto view = renderPCM(frame, reader.motion, reader.levels(), layout, levelMode,
                                  rendered.data(), rendered.size());
            if (view.availableSamples != ((uint64_t(1) << frame.samples) - 1))
                throw std::runtime_error("Object coordinates unavailable; export native elements to retain all PCM");
        }
        for (unsigned i = 0; i < frame.samples * channels; ++i) {
            if (native) rendered[i] = float(double(pcm[i]) / 8388608);
            else {
                double v = double(rendered[i]) * 8388608;
                if (v > 8388607 || v < -8388608) {
                    ++result.overRange;
                    if (format != Format::f32) ++result.clips;
                }
                pcm[i] = int32_t(std::llround(std::clamp(v, -8388608.0, 8388607.0)));
            }
        }
        if (format == Format::wave || format == Format::s24) wave->append(pcm.data(), frame.samples);
        else {
            for (unsigned i = 0; i < frame.samples * channels; ++i) {
                uint32_t bits;
                if (format == Format::s32) bits = uint32_t(pcm[i]) << 8;
                else std::memcpy(&bits, &rendered[i], sizeof(bits));
                wave->le(bits, 4);
            }
        }
        if (native && layer == 3 && reader.motion.update_count) {
            const auto &u = reader.motion.updates[0];
            std::string json = (update ? ",\n" : "") + std::string("    {\"sample\": ") +
                std::to_string(frame.first_sample + u.sample_offset) + ", \"rampSamples\": " +
                std::to_string(u.ramp_samples) + ", \"targets\": [";
            for (unsigned c = 0; c < channels; ++c) {
                auto p = u.targets[c];
                json += (c ? ", " : "") + std::string("[") + std::to_string(p.x) + ", " +
                         std::to_string(p.y) + ", " + std::to_string(p.z) + "]";
            }
            json += "]}"; sidecar->write(json.data(), json.size()); update = true;
        }
        result.samples += frame.samples;
        if (progress) progress(result.samples);
    }
    if (!wave) throw std::runtime_error("Input contains no audio");
    if (cancel) throw std::runtime_error("Export cancelled");
    result.checksumMismatches = reader.mismatches();
    std::string end = "\n  ],\n";
    if (native && reader.frame.presentations == 4) {
        end += "  \"positionsValid\": " + std::string(reader.frame.positions_valid ? "true" : "false") +
               ",\n  \"positionsDynamic\": " + std::string(reader.motion.positions_dynamic ? "true" : "false") +
               ",\n  \"positionsSnapshotSample\": " + std::to_string(result.samples - 1) + ",\n";
        if (reader.frame.positions_valid) {
            end += "  \"positions\": [";
            for (unsigned c = 0; c < channels; ++c) {
                auto p = reader.frame.positions[c];
                end += (c ? ", " : "") + std::string("[") + std::to_string(p.x) + ", " +
                       std::to_string(p.y) + ", " + std::to_string(p.z) + "]";
            }
            end += "],\n";
        }
    }
    end += "  \"dialnormApplied\": " + std::string(!native && levelMode == LevelMode::playback ? "true" : "false") +
        ",\n  \"clippedSamples\": " + std::to_string(result.clips) +
        ",\n  \"overRangeSamples\": " + std::to_string(result.overRange) +
        ",\n  \"pcmChecksumMismatches\": " + std::to_string(result.checksumMismatches) + "\n}\n";
    sidecar->write(end.data(), end.size()); wave->finish(); sidecar->finish();
    wave->file.committed = true; sidecar->committed = true;
    return result;
}
} // namespace sthd_qc
