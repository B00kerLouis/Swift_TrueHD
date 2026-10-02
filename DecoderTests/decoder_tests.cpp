// SPDX-License-Identifier: AGPL-3.0-only
#include "TrueHDDecoder.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
extern "C" int sthd_c_header_test(void);
namespace {
void expect(bool b, const std::string &s) {
    if (!b)
        throw std::runtime_error(s);
}
const char *names[] = {"2.0", "5.1", "7.1", "5.1.2", "5.1.4", "7.1.2", "7.1.4", "7.1.6", "9.1.6"};
STHDFrame fixture() {
    STHDFrame f{};
    f.samples = 40;
    f.sample_rate = 48000;
    f.presentations = 4;
    f.channels[0] = 2;
    f.channels[1] = 6;
    f.channels[2] = 8;
    f.channels[3] = 16;
    f.element_channels = 16;
    f.positions_valid = 1;
    const STHDPosition p[16] = {{0, 1, -1},  {-1, 1, 0}, {1, 1, 0},  {0, 1, 0},
                                {-1, -1, 0}, {1, -1, 0}, {-1, 0, 0}, {1, 0, 0},
                                {-1, 1, 1},  {1, 1, 1},  {-1, 0, 1}, {1, 0, 1},
                                {-1, -1, 1}, {1, -1, 1}, {0, 1, 1},  {0, -1, 1}};
    std::copy(p, p + 16, f.positions);
    return f;
}
void renderer_tests() {
    expect(sthd_c_header_test(), "C ABI header test");
    const unsigned counts[] = {2, 6, 8, 8, 10, 10, 12, 14, 16};
    STHDLayout l{};
    std::array<float, 640> out{};
    for (unsigned n = 0; n < 9; ++n) {
        expect(sthd_layout_named(names[n], &l) == STHD_OK && l.channels == counts[n],
               "layout channel count");
    }
    expect(sthd_layout_named("5.1.6", &l) == STHD_UNKNOWN_LAYOUT, "unknown layout rejected");
    auto f = fixture();
    for (unsigned i = 0; i < 16; ++i) {
        f.pcm[3][i] = 8388607;
        for (unsigned n = 3; n < 9; ++n) {
            sthd_layout_named(names[n], &l);
            expect(sthd_render(&f, &l, 1, out.data(), out.size()) == STHD_OK, "impulse render");
            double power = 0;
            for (unsigned c = 0; c < l.channels; ++c)
                power += double(out[c]) * out[c];
            expect(std::abs(power - 1.0) < 1e-5, "equal-power impulse conservation");
            for (unsigned c = 0; c < l.channels; ++c)
                if ((i == 0) != (l.speakers[c] == STHD_LFE))
                    expect(std::abs(out[c]) < 1e-6, "LFE isolation");
        }
        f.pcm[3][i] = 0;
    }
    sthd_layout_named("9.1.6", &l);
    const STHDSpeaker exact[] = {STHD_LFE, STHD_FL,  STHD_FR,  STHD_FC,  STHD_BL,
                                 STHD_BR,  STHD_SL,  STHD_SR,  STHD_TFL, STHD_TFR,
                                 STHD_TML, STHD_TMR, STHD_TBL, STHD_TBR};
    for (unsigned i = 0; i < 14; ++i) {
        f.pcm[3][i] = 4194304;
        expect(sthd_render(&f, &l, 1, out.data(), out.size()) == STHD_OK, "exact-anchor render");
        for (unsigned c = 0; c < l.channels; ++c)
            expect(std::abs(out[c] - (l.speakers[c] == exact[i] ? .5f : 0.f)) < 1e-6,
                   "speaker label routing");
        f.pcm[3][i] = 0;
    }
    // Five-channel floor layouts fold side and rear anchors into their
    // corresponding surround rather than spreading them into front speakers.
    STHDLayout five{};
    sthd_layout_named("5.1.4", &five);
    for (unsigned source : {4U, 6U}) {
        f.pcm[3][source] = 4194304;
        expect(sthd_render(&f, &five, 1, out.data(), out.size()) == STHD_OK, "5.1 surround fold");
        for (unsigned c = 0; c < five.channels; ++c)
            expect(std::abs(out[c] - (five.speakers[c] == STHD_SL ? .5f : 0.f)) < 1e-6,
                   "5.1 rear/side folding");
        f.pcm[3][source] = 0;
    }
    sthd_layout_named("5.1.4(back)", &five);
    for (unsigned source : {4U, 6U}) {
        f.pcm[3][source] = 4194304;
        expect(sthd_render(&f, &five, 1, out.data(), out.size()) == STHD_OK,
               "5.1 back-label render");
        for (unsigned c = 0; c < five.channels; ++c)
            expect(std::abs(out[c] - (five.speakers[c] == STHD_BL ? .5f : 0.f)) < 1e-6,
                   "5.1 back-label routing");
        f.pcm[3][source] = 0;
    }
    sthd_layout_named("5.1(back)", &five);
    expect(sthd_wave_channel_mask(&five) == 0x3f, "Windows conventional 5.1 mask");
    f.pcm[1][4] = 4194304;
    expect(sthd_render(&f, &five, 1, out.data(), out.size()) == STHD_OK && out[4] == .5f,
           "5.1 native presentation back labels");
    f.pcm[1][4] = 0;
    f.positions[1] = {-1, .5, 0};
    f.pcm[3][1] = 4194304;
    expect(sthd_render(&f, &l, 1, out.data(), out.size()) == STHD_OK, "front-wide render");
    for (unsigned c = 0; c < l.channels; ++c)
        expect(std::abs(out[c] - (l.speakers[c] == STHD_FWL ? .5f : 0.f)) < 1e-6,
               "front-wide position");
    auto canonical = out;
    std::reverse(l.speakers, l.speakers + l.channels);
    expect(sthd_render(&f, &l, 1, out.data(), out.size()) == STHD_OK, "physical reorder");
    for (unsigned c = 0; c < l.channels; ++c)
        expect(out[c] == canonical[l.channels - 1 - c], "physical channel order");
    l.speakers[1] = l.speakers[0];
    expect(sthd_render(&f, &l, 1, out.data(), out.size()) == STHD_INVALID_ARGUMENT,
           "duplicate speaker rejected");
    sthd_layout_named("7.1.4", &l);
    expect(sthd_render(&f, &l, 1, out.data(), 1) == STHD_BUFFER_TOO_SMALL, "output bounds");
    f.positions_valid = 0;
    expect(sthd_render(&f, &l, 1, out.data(), out.size()) == STHD_INVALID_ARGUMENT,
           "missing OAMD rejected");
    f = fixture();
    f.presentations = 3;
    f.element_channels = 0;
    f.pcm[2][0] = 4194304;
    expect(sthd_render(&f, &l, 1, out.data(), out.size()) == STHD_OK,
           "nonimmersive floor rendering");
    for (unsigned c = 0; c < l.channels; ++c)
        if (l.speakers[c] >= STHD_TFL)
            expect(out[c] == 0, "bed-only input does not invent height audio");
    sthd_layout_named("7.1", &l);
    for (unsigned i = 0; i < 8; ++i)
        f.pcm[2][i] = int32_t(i * 123456 - 500000);
    expect(sthd_render(&f, &l, 1, out.data(), out.size()) == STHD_OK,
           "lossless compatibility render");
    for (unsigned i = 0; i < 8; ++i)
        expect(double(out[i]) * 8388608 == f.pcm[2][i], "compatibility PCM precision");
    f.samples = 41;
    expect(sthd_render(&f, &l, 1, out.data(), out.size()) == STHD_INVALID_ARGUMENT, "frame bounds");
}
std::vector<uint8_t> read_au(std::ifstream &in) {
    uint8_t h[4];
    in.read(reinterpret_cast<char *>(h), 4);
    if (in.gcount() == 0 && in.eof())
        return {};
    expect(in.gcount() == 4, "truncated test input header");
    size_t bytes = ((unsigned(h[0]) & 15) * 256 + h[1]) * 2;
    expect(bytes >= 4 && bytes <= 8190, "test input AU length");
    std::vector<uint8_t> b(bytes);
    std::copy(h, h + 4, b.begin());
    in.read(reinterpret_cast<char *>(b.data() + 4), std::streamsize(bytes - 4));
    expect(size_t(in.gcount()) == bytes - 4, "truncated test input AU");
    return b;
}
void corrupt_tests(const std::filesystem::path &path) {
    std::ifstream in(path, std::ios::binary);
    auto first = read_au(in), second = read_au(in);
    expect(!first.empty() && !second.empty(), "corruption fixture needs two AUs");
    auto *d = sthd_decoder_create();
    expect(d != nullptr, "create decoder");
    STHDFrame f{}, control{};
    expect(sthd_decode_access_unit(d, second.data(), second.size(), &f) == STHD_NEED_RESTART,
           "restart required");
    expect(sthd_decode_access_unit(d, first.data(), first.size(), &f) == STHD_OK, "first AU");
    auto saved = f, bad = f;
    auto damaged = second;
    damaged[damaged.size() / 2] ^= 1;
    expect(sthd_decode_access_unit(d, damaged.data(), damaged.size(), &bad) != STHD_OK,
           "corrupt payload rejected");
    expect(std::memcmp(&saved, &bad, sizeof(saved)) == 0, "failed decode leaves output untouched");
    expect(sthd_decode_access_unit(d, second.data(), second.size(), &control) == STHD_OK &&
               control.first_sample == 40,
           "failed decode leaves state untouched");
    // Every single-bit mutation of a real first AU must fail integrity checks.
    for (size_t i = 0; i < first.size(); ++i)
        for (unsigned bit = 0; bit < 8; ++bit) {
            auto v = first;
            v[i] ^= uint8_t(1U << bit);
            sthd_decoder_reset(d);
            expect(sthd_decode_access_unit(d, v.data(), v.size(), &f) != STHD_OK,
                   "single-bit corruption accepted at byte " + std::to_string(i));
        }
    uint32_t rng = 0x5eed1234;
    for (unsigned t = 0; t < 2000; ++t) {
        rng = rng * 1664525 + 1013904223;
        size_t n = 4 + (rng % 400);
        std::vector<uint8_t> v(n);
        for (auto &x : v) {
            rng = rng * 1664525 + 1013904223;
            x = uint8_t(rng >> 24);
        }
        v[0] = uint8_t((n / 2) >> 8);
        v[1] = uint8_t(n / 2);
        sthd_decoder_reset(d);
        expect(sthd_decode_access_unit(d, v.data(), v.size(), &f) != STHD_OK,
               "random malformed stream accepted");
    }
    sthd_decoder_destroy(d);
}
void compare(std::ifstream &ref, const int32_t *pcm, size_t count, uint64_t au, unsigned layer) {
    std::vector<uint8_t> b(count * 3);
    ref.read(reinterpret_cast<char *>(b.data()), std::streamsize(b.size()));
    expect(size_t(ref.gcount()) == b.size(), "reference ended early");
    for (size_t i = 0; i < count; ++i) {
        uint32_t u = uint32_t(pcm[i]);
        expect(b[i * 3] == uint8_t(u) && b[i * 3 + 1] == uint8_t(u >> 8) &&
                   b[i * 3 + 2] == uint8_t(u >> 16),
               "PCM mismatch AU " + std::to_string(au) + " presentation " + std::to_string(layer) +
                   " sample " + std::to_string(i));
    }
}
void audio_policy_tests() {
    auto f = fixture();
    STHDDecodedPresentation v{};
    expect(sthd_presentation(&f, STHD_PRESENTATION_IMMERSIVE, &v) == STHD_OK,
           "immersive presentation view");
    expect(v.bed_layout.channels == 1 && v.bed_layout.speakers[0] == STHD_LFE &&
               v.object_count == 15,
           "objects remain separate from bed");
    for (unsigned i = 0; i < v.object_count; ++i)
        expect(v.objects[i].id == i + 1 && v.objects[i].pcm == f.pcm[3] + i + 1 &&
                   v.objects[i].sample_stride == 16,
               "object ID/PCM stride");
    STHDAudioCapabilities caps{};
    caps.pcm_backend = STHD_AUDIO_WASAPI;
    caps.pcm_available = 1;
    caps.pcm_channels = 2;
    caps.pcm_layout_valid = 1;
    sthd_layout_named("2.0", &caps.pcm_layout);
    caps.spatial_available = 1;
    caps.max_dynamic_objects = 15;
    caps.spatial_speaker_mask = (1U << 12) - 1;
    STHDAudioPlan plan{};
    expect(sthd_audio_plan(&f, &caps, nullptr, 0, &plan) == STHD_OK &&
               plan.backend == STHD_AUDIO_WINDOWS_SPATIAL &&
               plan.mode == STHD_AUDIO_POSITIONAL_OBJECTS && plan.object_count == 15,
           "Windows positional object plan");
    caps.max_dynamic_objects = 0;
    expect(sthd_audio_plan(&f, &caps, nullptr, 0, &plan) == STHD_OK &&
               plan.mode == STHD_AUDIO_STATIC_OBJECTS && plan.layout.channels == 12,
           "Windows static height plan");
    caps.spatial_available = 0;
    expect(sthd_audio_plan(&f, &caps, nullptr, 0, &plan) == STHD_UNSUPPORTED_OUTPUT,
           "no silent Windows immersive PCM fallback");
    expect(sthd_audio_plan(&f, &caps, nullptr, 1, &plan) == STHD_OK &&
               plan.backend == STHD_AUDIO_WASAPI,
           "explicit immersive PCM fallback");
    caps.pcm_backend = STHD_AUDIO_PIPEWIRE;
    caps.pcm_layout_valid = 0;
    caps.pcm_channels = 16;
    STHDLayout explicit_layout{};
    sthd_layout_named("9.1.6", &explicit_layout);
    expect(sthd_audio_plan(&f, &caps, nullptr, 0, &plan) == STHD_UNKNOWN_LAYOUT,
           "discrete outputs are not 9.1.6 by count");
    expect(sthd_audio_plan(&f, &caps, &explicit_layout, 0, &plan) == STHD_OK &&
               plan.layout.channels == 16,
           "explicit physical layout");
    caps.pcm_channels = 2;
    expect(sthd_audio_plan(&f, &caps, &explicit_layout, 0, &plan) == STHD_UNSUPPORTED_OUTPUT,
           "reject incompatible physical channel count");
    f.presentations = 3;
    caps.pcm_backend = STHD_AUDIO_WASAPI;
    caps.pcm_layout_valid = 1;
    caps.spatial_available = 1;
    expect(sthd_audio_plan(&f, &caps, nullptr, 0, &plan) == STHD_OK &&
               plan.backend == STHD_AUDIO_WASAPI,
           "ordinary TrueHD bypasses spatial pipeline");
    expect(sthd_presentation(&f, STHD_PRESENTATION_71, &v) == STHD_OK && v.object_count == 0 &&
               v.bed_sample_stride == 8,
           "channel presentation view");
    std::array<float, 640> out{};
    STHDLayout stereo{}, five{};
    sthd_layout_named("2.0", &stereo);
    sthd_layout_named("5.1", &five);
    for (unsigned source : {2U, 4U, 6U}) {
        f.pcm[2][source] = 4194304;
        expect(sthd_render(&f, &stereo, 1, out.data(), out.size()) == STHD_OK && out[0] > 0.35f,
               "plain 7.1 centre/rear/side retained in stereo downmix");
        if (source != 2)
            expect(sthd_render(&f, &five, 1, out.data(), out.size()) == STHD_OK && out[4] > 0.35f,
                   "plain 7.1 rear/side retained in 5.1 downmix");
        f.pcm[2][source] = 0;
    }
}
void stream_tests(const std::filesystem::path &path, const std::string &prefix) {
    corrupt_tests(path);
    std::ifstream in(path, std::ios::binary);
    expect(bool(in), "open test stream");
    std::array<std::ifstream, 4> refs;
    const char *suffix[] = {".2.pcm", ".6.pcm", ".8.pcm", ".elements.pcm"};
    unsigned compared = 0;
    if (!prefix.empty())
        for (unsigned i = 0; i < 4; ++i) {
            auto p = std::filesystem::u8path(prefix + suffix[i]);
            if (std::filesystem::exists(p)) {
                refs[i].open(p, std::ios::binary);
                expect(bool(refs[i]), "open PCM reference");
                compared |= 1U << i;
            }
        }
    auto *d = sthd_decoder_create();
    expect(d != nullptr, "create decoder");
    STHDFrame f{};
    std::array<STHDLayout, 9> layouts{};
    for (unsigned i = 0; i < 9; ++i)
        sthd_layout_named(names[i], &layouts[i]);
    double peaks[9]{};
    uint64_t clipped[9]{};
    double energies[9][16]{};
    uint64_t au = 0, samples = 0;
    while (true) {
        auto bytes = read_au(in);
        if (bytes.empty())
            break;
        auto s = sthd_decode_access_unit(d, bytes.data(), bytes.size(), &f);
        expect(s == STHD_OK, "decode AU " + std::to_string(au) + ": " + sthd_decoder_error(d));
        expect(f.first_sample == samples, "continuous sample timeline");
        for (unsigned i = 0; i < f.presentations; ++i)
            if (compared & (1U << i))
                compare(refs[i], f.pcm[i], size_t(f.samples) * f.channels[i], au, i);
        for (unsigned i = 0; i < 9; ++i) {
            std::array<float, 640> out{};
            expect(sthd_render(&f, &layouts[i], 1, out.data(), out.size()) == STHD_OK,
                   "stream render");
            for (unsigned n = 0; n < f.samples; ++n)
                for (unsigned c = 0; c < layouts[i].channels; ++c) {
                    double v = out[n * layouts[i].channels + c];
                    expect(std::isfinite(v), "nonfinite rendered PCM");
                    peaks[i] = std::max(peaks[i], std::abs(v));
                    if (v > 8388607.0 / 8388608 || v < -1)
                        ++clipped[i];
                    energies[i][c] += v * v;
                }
        }
        samples += f.samples;
        ++au;
    }
    for (unsigned i = 0; i < 4; ++i)
        if (compared & (1U << i))
            expect(refs[i].peek() == EOF, "reference has extra samples");
    expect(au > 0, "empty test stream");
    sthd_decoder_destroy(d);
    std::cout << "{\"accessUnits\":" << au << ",\"samples\":" << samples
              << ",\"elements\":" << f.element_channels
              << ",\"referencePresentations\":" << compared << ",\"layouts\":[\n";
    for (unsigned i = 0; i < 9; ++i) {
        std::cout << "{\"name\":\"" << names[i] << "\",\"channels\":" << layouts[i].channels
                  << ",\"peak\":" << peaks[i] << ",\"clipped\":" << clipped[i] << ",\"rms\":[";
        for (unsigned c = 0; c < layouts[i].channels; ++c)
            std::cout << (c ? "," : "") << std::sqrt(energies[i][c] / double(samples));
        std::cout << "]}" << (i == 8 ? "" : ",") << "\n";
    }
    std::cout << "]}\n";
}
void generate(const std::filesystem::path &path, const std::string &prefix = "") {
    std::ofstream out(path, std::ios::binary);
    expect(bool(out), "create synthetic WAVE");
    auto le = [&](uint32_t v, unsigned n) {
        for (unsigned i = 0; i < n; ++i)
            out.put(char(v >> (8 * i)));
    };
    constexpr unsigned samples = 12345, channels = 8;
    out.write("RIFF", 4);
    le(36 + samples * channels * 3, 4);
    out.write("WAVEfmt ", 8);
    le(16, 4);
    le(1, 2);
    le(channels, 2);
    le(48000, 4);
    le(48000 * channels * 3, 4);
    le(channels * 3, 2);
    le(24, 2);
    out.write("data", 4);
    le(samples * channels * 3, 4);
    std::ofstream reference;
    if (!prefix.empty()) {
        reference.open(std::filesystem::u8path(prefix + ".8.pcm"), std::ios::binary);
        expect(bool(reference), "create PCM reference");
    }
    uint32_t rng = 0x11223344;
    for (unsigned n = 0; n < samples; ++n)
        for (unsigned c = 0; c < channels; ++c) {
            rng = rng * 1664525 + 1013904223;
            int32_t v = n < 400
                            ? ((n % 50 == 0 && c == n / 50) ? 4194304 : 0)
                            : (n < 4000 ? int32_t(2000000 * std::sin(double(n) * (c + 1) * .007))
                                        : int32_t(rng & 0xffffff) - 0x800000);
            le(uint32_t(v), 3);
            if (reference)
                for (unsigned i = 0; i < 3; ++i)
                    reference.put(char(uint32_t(v) >> (i * 8)));
        }
}
} // namespace
int main(int argc, char **argv) {
    try {
        renderer_tests();
        audio_policy_tests();
        if (argc >= 3 && std::string(argv[1]) == "--stream")
            stream_tests(std::filesystem::u8path(argv[2]), argc >= 4 ? argv[3] : "");
        else if ((argc == 3 || argc == 4) && std::string(argv[1]) == "--generate")
            generate(std::filesystem::u8path(argv[2]), argc == 4 ? argv[3] : "");
        else if (argc != 1)
            throw std::runtime_error("Usage: decoder_tests [--stream INPUT.mlp [REFERENCE_PREFIX] "
                                     "| --generate OUTPUT.wav]");
        else
            std::cout << "C ABI, nine layouts, impulse power, LFE isolation, anchor/wide routing, "
                         "device ordering, bounds: passed\n";
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "FAIL: " << e.what() << "\n";
        return 1;
    }
}
