// SPDX-License-Identifier: AGPL-3.0-only
#include "TrueHDDecoder.h"
#include <algorithm>
#include <array>
#include <cerrno>
#include <cmath>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <fcntl.h>
#include <io.h>
#include <share.h>
#include <sys/stat.h>
#include <windows.h>
#endif
namespace fs = std::filesystem;
namespace {
volatile std::sig_atomic_t interrupted = 0;
void cancel_signal(int) { interrupted = 1; }
void fail(const std::string &s) { throw std::runtime_error(s); }
void check(STHDStatus s) {
    if (s != STHD_OK)
        fail(sthd_status_string(s));
}
void usage() {
    std::cout
        << "Usage: truehdd -i INPUT.mlp -o OUTPUT.wav [--layout NAME | --presentation "
           "2|6|8|elements]\n"
           "Layouts: auto, 2.0, 5.1, 7.1, 5.1.2, 5.1.4, 7.1.2, 7.1.4, 7.1.6, 9.1.6\n"
           "5.1 family also accepts (back) suffix for BL/BR surround labels.\n"
           "  --layout auto            Read the actual default device speaker labels (default)\n"
           "  --speaker-order LABELS   Comma-separated physical order for the selected layout\n"
           "  --format wav|s24le       WAVE/RF64 or packed signed 24-bit little-endian PCM\n"
           "  --gain-db DB             Render gain (-120 to +24 dB, default 0)\n"
           "  --verify-only            Decode and validate all AUs without writing PCM\n"
           "  --device-info            Show the default output device topology\n"
           "PCM: 48 kHz / 24 bit WAVE, RF64 when needed; channel labels in .channels.json.\n"
           "  --play                   Play through the native backend (output file optional)\n"
           "  --allow-pcm-fallback     Permit Windows immersive output through WASAPI PCM\n"
           "No DRC is applied. Playback and file rendering retain separate output plans.\n";
}
FILE *exclusive_file(const fs::path &p) {
#ifdef _WIN32
    int descriptor = -1;
    if (_wsopen_s(&descriptor, p.c_str(), _O_CREAT | _O_EXCL | _O_WRONLY | _O_BINARY, _SH_DENYRW,
                  _S_IREAD | _S_IWRITE) != 0)
        return nullptr;
    FILE *f = _fdopen(descriptor, "wb");
    if (!f) {
        _close(descriptor);
        std::error_code ec;
        fs::remove(p, ec);
    }
    return f;
#else
    return std::fopen(p.c_str(), "wbx");
#endif
}
struct File {
    fs::path path;
    FILE *handle = nullptr;
    bool committed = false;
    explicit File(fs::path p) : path(std::move(p)) {
        handle = exclusive_file(path);
        if (!handle)
            fail("cannot exclusively create output: " + path.u8string() + ": " +
                 std::strerror(errno));
    }
    ~File() {
        if (handle)
            std::fclose(handle);
        if (!committed) {
            std::error_code ec;
            fs::remove(path, ec);
        }
    }
    void write(const void *p, size_t n) {
        if (std::fwrite(p, 1, n, handle) != n)
            fail("output write failed: " + path.u8string());
    }
    void seek(uint64_t offset) {
#ifdef _WIN32
        if (_fseeki64(handle, static_cast<__int64>(offset), SEEK_SET))
            fail("output seek failed");
#else
        if (fseeko(handle, static_cast<off_t>(offset), SEEK_SET))
            fail("output seek failed");
#endif
    }
    void finish() {
        if (std::fflush(handle) != 0)
            fail("output flush failed");
        int status = std::fclose(handle);
        handle = nullptr;
        if (status)
            fail("output close failed");
    }
};
struct Wave {
    File file;
    uint32_t channels, mask;
    uint64_t frames = 0, bytes = 0;
    bool raw_pcm;
    Wave(const fs::path &p, unsigned c, uint32_t m, bool raw = false)
        : file(p), channels(c), mask(m), raw_pcm(raw) {
        if (!raw_pcm)
            header(false);
    }
    void le(uint64_t v, unsigned n) {
        std::array<uint8_t, 8> b{};
        for (unsigned i = 0; i < n; ++i)
            b[i] = uint8_t(v >> (8 * i));
        file.write(b.data(), n);
    }
    void tag(const char *p) { file.write(p, 4); }
    void header(bool final) {
        file.seek(0);
        bool rf64 = bytes > 0xffffffffULL - 96;
        tag(rf64 ? "RF64" : "RIFF");
        le(rf64 ? 0xffffffffU : (final ? bytes + 96 + (bytes & 1) : 0), 4);
        tag("WAVE");
        tag(rf64 ? "ds64" : "JUNK");
        le(28, 4);
        le(rf64 ? bytes + 96 + (bytes & 1) : 0, 8);
        le(rf64 ? bytes : 0, 8);
        le(rf64 ? frames : 0, 8);
        le(0, 4);
        tag("fmt ");
        le(40, 4);
        le(0xfffe, 2);
        le(channels, 2);
        le(48000, 4);
        le(48000 * channels * 3, 4);
        le(channels * 3, 2);
        le(24, 2);
        le(22, 2);
        le(24, 2);
        le(mask, 4);
        const uint8_t guid[16] = {1, 0, 0, 0, 0, 0, 16, 0, 128, 0, 0, 170, 0, 56, 155, 113};
        file.write(guid, 16);
        tag("data");
        le(rf64 ? 0xffffffffU : (final ? bytes : 0), 4);
    }
    void append(const int32_t *p, unsigned samples) {
        std::array<uint8_t, 40 * 16 * 3> b{};
        size_t n = size_t(samples) * channels;
        for (size_t i = 0; i < n; ++i) {
            uint32_t v = uint32_t(p[i]);
            b[i * 3] = uint8_t(v);
            b[i * 3 + 1] = uint8_t(v >> 8);
            b[i * 3 + 2] = uint8_t(v >> 16);
        }
        file.write(b.data(), n * 3);
        bytes += n * 3;
        frames += samples;
    }
    void finish() {
        if (!raw_pcm) {
            if (bytes & 1) {
                const uint8_t zero = 0;
                file.write(&zero, 1);
            }
            header(true);
        }
        file.finish();
    }
};
std::string channels_json(const STHDLayout *layout, const STHDFrame &frame, int presentation) {
    std::string out = "{\n  \"sampleRate\": 48000,\n  \"validBits\": 24,\n  \"drcApplied\": "
                      "false,\n  \"channels\": [\n";
    unsigned channels = layout ? layout->channels : frame.channels[unsigned(presentation)];
    for (unsigned c = 0; c < channels; ++c) {
        out += "    {\"index\": " + std::to_string(c) + ", ";
        if (presentation == 3) {
            auto p = frame.positions[c];
            out += "\"element\": " + std::to_string(c) +
                   ", \"lfe\": " + (c == 0 ? std::string("true") : std::string("false")) +
                   ", \"x\": " + std::to_string(p.x) + ", \"y\": " + std::to_string(p.y) +
                   ", \"z\": " + std::to_string(p.z);
        } else {
            STHDSpeaker s = layout->speakers[c];
            out += "\"speaker\": \"" + std::string(sthd_speaker_name(s)) + "\"";
        }
        out += "}";
        if (c + 1 < channels)
            out += ",";
        out += "\n";
    }
    return out + "  ]\n}\n";
}
int run(const std::vector<std::string> &args) {
    std::string input, output, name = "auto", order;
    int presentation = -1;
    bool verify = false, device = false, layout_selected = false, raw_pcm = false, play = false,
         pcm_fallback = false;
    double gain_db = 0;
    for (size_t i = 0; i < args.size(); ++i) {
        const std::string &a = args[i];
        auto value = [&]() {
            if (++i >= args.size())
                fail("missing value for " + a);
            return args[i];
        };
        if (a == "--help" || a == "-h") {
            usage();
            return 0;
        }
        if (a == "-i" || a == "--input")
            input = value();
        else if (a == "-o" || a == "--output")
            output = value();
        else if (a == "--layout") {
            name = value();
            layout_selected = true;
        } else if (a == "--speaker-order")
            order = value();
        else if (a == "--presentation") {
            auto p = value();
            if (p == "2")
                presentation = 0;
            else if (p == "6")
                presentation = 1;
            else if (p == "8")
                presentation = 2;
            else if (p == "elements")
                presentation = 3;
            else
                fail("invalid presentation");
        } else if (a == "--gain-db") {
            auto v = value();
            size_t consumed = 0;
            gain_db = std::stod(v, &consumed);
            if (consumed != v.size() || !std::isfinite(gain_db) || gain_db < -120 || gain_db > 24)
                fail("gain must be -120 to +24 dB");
        } else if (a == "--format") {
            auto v = value();
            if (v == "s24le")
                raw_pcm = true;
            else if (v != "wav")
                fail("format must be wav or s24le");
        } else if (a == "--verify-only")
            verify = true;
        else if (a == "--device-info")
            device = true;
        else if (a == "--play")
            play = true;
        else if (a == "--allow-pcm-fallback")
            pcm_fallback = true;
        else
            fail("unknown option: " + a);
    }
    if (args.empty()) {
        usage();
        return 0;
    }
    if (layout_selected && presentation >= 0)
        fail("--layout and --presentation are mutually exclusive");
    if (presentation >= 0 && (!order.empty() || gain_db != 0))
        fail("exact presentation extraction cannot change order or gain");
    STHDLayout layout{};
    if (device) {
        STHDAudioCapabilities caps{};
        auto status = sthd_audio_capabilities(&caps);
        std::cout << "PCM backend=" << sthd_audio_backend_name(caps.pcm_backend)
                  << ", channels=" << caps.pcm_channels << ", rate=" << caps.pcm_sample_rate
                  << ", labels=" << (caps.pcm_layout_valid ? "known" : "unknown") << "\n";
        if (caps.pcm_layout_valid) {
            for (unsigned i = 0; i < caps.pcm_layout.channels; ++i)
                std::cout << (i ? "," : "") << sthd_speaker_name(caps.pcm_layout.speakers[i]);
            std::cout << "\n";
        }
        std::cout << "Spatial available=" << caps.spatial_available
                  << ", supported speaker mask=" << caps.spatial_speaker_mask
                  << ", dynamic objects=" << caps.max_dynamic_objects << "\n";
        if (input.empty())
            return status == STHD_OK ? 0 : 2;
    }
    if (input.empty() || (!verify && !play && output.empty()))
        fail("input and output are required (output optional with --verify-only)");
    if (verify && (!output.empty() || play))
        fail("--verify-only does not take an output path");
    if (play && presentation >= 0)
        fail(
            "playback uses decoded presentation semantics; --presentation is an extraction option");
    if (pcm_fallback && !play)
        fail("--allow-pcm-fallback requires --play");
    if (!verify) {
        if (presentation < 0) {
            if (name == "auto" && (!play || !output.empty())) {
                char description[256];
                auto s = sthd_default_device_layout(&layout, description, sizeof(description));
                if (s != STHD_OK)
                    fail(std::string(description) + "; select --layout explicitly");
                std::cout << description << "\n";
            } else if (name != "auto")
                check(sthd_layout_named(name.c_str(), &layout));
            if (!order.empty()) {
                STHDLayout requested{};
                size_t at = 0;
                do {
                    size_t end = order.find(',', at);
                    std::string label = order.substr(at, end == std::string::npos ? end : end - at);
                    bool found = false;
                    for (unsigned s = 0; s < 16; ++s)
                        if (label == sthd_speaker_name(STHDSpeaker(s))) {
                            if (requested.channels >= 16)
                                fail("too many channel labels");
                            requested.speakers[requested.channels++] = STHDSpeaker(s);
                            found = true;
                            break;
                        }
                    if (!found)
                        fail("unknown speaker: " + label);
                    if (end == std::string::npos)
                        break;
                    at = end + 1;
                } while (true);
                unsigned a = 0, b = 0;
                for (unsigned c = 0; c < layout.channels; ++c)
                    a |= 1U << unsigned(layout.speakers[c]);
                for (unsigned c = 0; c < requested.channels; ++c) {
                    unsigned bit = 1U << unsigned(requested.speakers[c]);
                    if (b & bit)
                        fail("duplicate speaker label");
                    b |= bit;
                }
                if (a != b || layout.channels != requested.channels)
                    fail("speaker order does not match selected layout");
                layout = requested;
            }
        } else if (presentation < 3)
            check(sthd_layout_named(presentation == 0 ? "2.0" : (presentation == 1 ? "5.1" : "7.1"),
                                    &layout));
    }
    fs::path source = fs::u8path(input), destination = fs::u8path(output);
    std::ifstream in(source, std::ios::binary);
    if (!in)
        fail("cannot open input: " + input);
    std::unique_ptr<STHDDecoder, decltype(&sthd_decoder_destroy)> decoder(sthd_decoder_create(),
                                                                          sthd_decoder_destroy);
    if (!decoder)
        fail("out of memory");
    std::unique_ptr<STHDAudioOutput, decltype(&sthd_audio_close)> audio(nullptr, sthd_audio_close);
    std::unique_ptr<Wave> wave;
    std::unique_ptr<File> sidecar;
    STHDFrame frame{};
    uint64_t au = 0, samples = 0, clipped = 0;
    double peak = 0;
    std::array<uint8_t, STHD_MAX_ACCESS_UNIT> bytes{};
    while (true) {
        if (interrupted)
            fail("decode cancelled");
        in.read(reinterpret_cast<char *>(bytes.data()), 4);
        auto got = in.gcount();
        if (got == 0 && in.eof())
            break;
        if (got != 4)
            fail("truncated access header at AU " + std::to_string(au));
        const size_t size = ((unsigned(bytes[0]) & 15) * 256 + bytes[1]) * 2;
        if (size < 4 || size > bytes.size())
            fail("invalid access unit size at AU " + std::to_string(au));
        in.read(reinterpret_cast<char *>(bytes.data() + 4), std::streamsize(size - 4));
        if (size_t(in.gcount()) != size - 4)
            fail("truncated payload at AU " + std::to_string(au));
        auto status = sthd_decode_access_unit(decoder.get(), bytes.data(), size, &frame);
        if (status != STHD_OK)
            fail("AU " + std::to_string(au) + ": " + sthd_status_string(status) + ": " +
                 sthd_decoder_error(decoder.get()));
        if (play) {
            if (!audio) {
                STHDAudioCapabilities caps{};
                check(sthd_audio_capabilities(&caps));
                STHDAudioPlan plan{};
                check(sthd_audio_plan(&frame, &caps, name == "auto" ? nullptr : &layout,
                                      pcm_fallback ? 1 : 0, &plan));
                char message[256];
                audio.reset(sthd_audio_open(&plan, message, sizeof(message)));
                if (!audio)
                    fail(message);
                std::cout << "Playback backend=" << sthd_audio_backend_name(plan.backend)
                          << ", mode=" << plan.mode << ", positional feeds=" << plan.object_count
                          << "\n";
            }
            if (interrupted)
                fail("decode cancelled");
            auto status =
                sthd_audio_write(audio.get(), &frame, float(std::pow(10.0, gain_db / 20)), 5000);
            if (status != STHD_OK)
                fail(std::string(sthd_status_string(status)) + ": " +
                     sthd_audio_error(audio.get()));
        }
        if (!verify && !output.empty()) {
            if (presentation == 3 && frame.presentations < 4)
                fail("stream has no Atmos element presentation");
            if (!wave) {
                sidecar = std::make_unique<File>(fs::u8path(output + ".channels.json"));
                auto json =
                    channels_json(presentation == 3 ? nullptr : &layout, frame, presentation);
                sidecar->write(json.data(), json.size());
                wave = std::make_unique<Wave>(
                    destination, presentation == 3 ? frame.element_channels : layout.channels,
                    presentation == 3 ? 0 : sthd_wave_channel_mask(&layout), raw_pcm);
            }
            if (presentation >= 0) {
                const int32_t *pcm = frame.pcm[unsigned(presentation)];
                for (unsigned i = 0; i < frame.samples * frame.channels[unsigned(presentation)];
                     ++i)
                    peak = std::max(peak, std::abs(double(pcm[i])) / 8388608.0);
                wave->append(pcm, frame.samples);
            } else {
                std::array<float, 40 * 16> rendered{};
                std::array<int32_t, 40 * 16> pcm{};
                check(sthd_render(&frame, &layout, float(std::pow(10.0, gain_db / 20)),
                                  rendered.data(), rendered.size()));
                for (unsigned i = 0; i < frame.samples * layout.channels; ++i) {
                    double v = double(rendered[i]) * 8388608.0;
                    peak = std::max(peak, std::abs(v) / 8388608.0);
                    if (v > 8388607 || v < -8388608)
                        ++clipped;
                    pcm[i] = int32_t(std::llround(std::clamp(v, -8388608.0, 8388607.0)));
                }
                wave->append(pcm.data(), frame.samples);
            }
        }
        samples += frame.samples;
        ++au;
        if (frame.samples < 40) {
            if (in.peek() != EOF)
                fail("data follows final PCM trim marker");
            break;
        }
    }
    if (!au)
        fail("input contains no access units");
    if (audio) {
        check(sthd_audio_drain(audio.get(), 5000));
        STHDAudioStats stats{};
        sthd_audio_stats(audio.get(), &stats);
        std::cout << "Playback consumed=" << stats.consumed_frames
                  << ", underruns=" << stats.underruns << "\n";
    }
    if (wave) {
        wave->finish();
        sidecar->finish();
        wave->file.committed = true;
        sidecar->committed = true;
    }
    std::cout << "Decoded " << au << " AUs, " << samples << " samples, " << double(samples) / 48000
              << " seconds, " << frame.element_channels << " Atmos elements\n";
    if (wave)
        std::cout << "Wrote " << wave->channels << " channels; peak=" << peak
                  << ", clipped samples=" << clipped << ", DRC disabled\n";
    return 0;
}
int safe_run(const std::vector<std::string> &args) {
    std::signal(SIGINT, cancel_signal);
    std::signal(SIGTERM, cancel_signal);
    try {
        return run(args);
    } catch (const std::exception &e) {
        std::cerr << "error: " << e.what() << "\n";
        return 1;
    }
}
} // namespace
#ifdef _WIN32
int wmain(int argc, wchar_t **argv) {
    std::vector<std::string> args;
    for (int i = 1; i < argc; ++i) {
        int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, argv[i], -1, nullptr, 0, nullptr,
                                    nullptr);
        if (!n)
            return 1;
        std::string s(size_t(n), '\0');
        WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, argv[i], -1, s.data(), n, nullptr,
                            nullptr);
        s.pop_back();
        args.push_back(std::move(s));
    }
    return safe_run(args);
}
#else
int main(int argc, char **argv) {
    return safe_run(std::vector<std::string>(argv + 1, argv + argc));
}
#endif
