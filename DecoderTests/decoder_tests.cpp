// SPDX-License-Identifier: LGPL-2.1-or-later
#include "../Sources/DecoderFramework/AudioBackend.hpp"
#if defined(STHD_TEST_COREAUDIO_MAPS)
#include <AudioToolbox/AudioToolbox.h>
#endif
#include "TrueHDDecoder.h"
#include "../Sources/DecoderFramework/BitReader.hpp"
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
void sthd_matrix_syntax_tests(const char *fixture);
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
// Independent bit-serial MLP CRC calculation for integrity-preserving header
// mutations. Random bytes with broken CRCs do not exercise profile parsing.
uint16_t header_crc(const uint8_t *p, size_t count) {
    uint16_t crc = 0;
    for (size_t i = 0; i + 2 < count; ++i) {
        crc ^= uint16_t(unsigned(p[i]) << 8);
        for (unsigned bit = 0; bit < 8; ++bit)
            crc = uint16_t((unsigned(crc) << 1) ^ ((crc & 0x8000) ? 0x2d : 0));
    }
    return uint16_t((crc >> 8) | (unsigned(crc) << 8)) ^
           uint16_t(p[count - 2] | (unsigned(p[count - 1]) << 8));
}
void seal_major(std::vector<uint8_t> &au, size_t sync_size) {
    uint16_t crc = header_crc(au.data() + 4, sync_size - 2);
    au[4 + sync_size - 2] = uint8_t(crc);
    au[4 + sync_size - 1] = uint8_t(crc >> 8);
    unsigned parity = unsigned(au.size() / 2) ^
                      ((unsigned(au[2]) << 8) | au[3]);
    size_t at = 4 + sync_size;
    for (unsigned i = 0; i < (au[20] >> 4); ++i) {
        unsigned word = (unsigned(au[at]) << 8) | au[at + 1];
        parity ^= au[at] ^ au[at + 1];
        at += 2;
        if (word & 0x8000) {
            parity ^= au[at] ^ au[at + 1];
            at += 2;
        }
    }
    parity ^= parity >> 8;
    parity ^= parity >> 4;
    unsigned header = ((parity ^ 15) & 15) << 12 | unsigned(au.size() / 2);
    au[0] = uint8_t(header >> 8);
    au[1] = uint8_t(header);
}
void major_header_tests(const std::vector<uint8_t> &first) {
    const size_t original_size = (first[29] & 1) ? 30 + (first[30] >> 4) * 2 : 28;
    expect(header_crc(first.data() + 4, original_size - 2) ==
               uint16_t(first[4 + original_size - 2] |
                        (unsigned(first[4 + original_size - 1]) << 8)),
           "independent major CRC oracle");
    std::unique_ptr<STHDDecoder, decltype(&sthd_decoder_destroy)> d(
        sthd_decoder_create(), sthd_decoder_destroy);
    STHDFrame frame{};
    auto rejected = [&](std::vector<uint8_t> au, size_t sync_size, const char *message) {
        seal_major(au, sync_size);
        sthd_decoder_reset(d.get());
        auto saved = frame;
        expect(sthd_decode_access_unit(d.get(), au.data(), au.size(), &frame) ==
                   STHD_UNSUPPORTED_STREAM,
               message);
        expect(std::memcmp(&frame, &saved, sizeof(frame)) == 0,
               "unsupported major header leaves output untouched");
        expect(sthd_decode_access_unit(d.get(), first.data(), first.size(), &frame) == STHD_OK,
               "unsupported major header leaves initial state untouched");
    };
    auto changed = first;
    changed[9] ^= 0x40; // Stereo channel modifier.
    rejected(changed, original_size, "valid CRC with unsupported modifier rejected");
    changed = first;
    changed[11] ^= 1; // Eight-channel arrangement.
    rejected(changed, original_size, "valid CRC with unsupported arrangement rejected");
    changed = first;
    changed[20] ^= 1; // Extended substream info.
    rejected(changed, original_size, "valid CRC with unsupported presentation flags rejected");
    if (original_size == 28) {
        changed = first;
        changed.insert(changed.begin() + 30, 2, 0);
        changed[29] |= 1;
        changed[30] = 0; // Extension present, zero extension pairs: actual size 30.
        rejected(changed, 30, "actual 30-byte extension parsed before unsupported rejection");
    } else {
        changed = first;
        changed.insert(changed.begin() + 34, 4, 0);
        changed[30] = uint8_t((changed[30] & 15) | 0x30);
        rejected(changed, 36, "actual 36-byte extension parsed before unsupported rejection");
    }
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
void player_transport_tests() {
    STHDPlayerOptions options{};
    options.struct_size = sizeof(options);
    options.gain = 0;
    char error[256];
    for (size_t length : {1U, 2U, 3U, 4U, 17U}) {
        std::unique_ptr<STHDPlayer, decltype(&sthd_player_destroy)> player(
            sthd_player_create(&options, error, sizeof(error)), sthd_player_destroy);
        expect(bool(player), "device-independent player construction");
        std::array<uint8_t, 17> packet{};
        packet[1] = 64;
        size_t consumed = 0;
        expect(sthd_player_feed(player.get(), packet.data(), length, &consumed, 0) == STHD_OK &&
                   consumed == length,
               "partial header/payload accepted");
        STHDPlayerStats stats{};
        sthd_player_stats(player.get(), &stats);
        expect(stats.buffered_bytes == length && stats.decoded_access_units == 0,
               "bounded incomplete AU state");
        expect(sthd_player_finish(player.get(), 0) == STHD_CORRUPT_STREAM,
               "truncated stream rejected before output opens");
    }
    std::unique_ptr<STHDPlayer, decltype(&sthd_player_destroy)> player(
        sthd_player_create(&options, error, sizeof(error)), sthd_player_destroy);
    uint8_t bad[4]{};
    size_t consumed = 0;
    expect(sthd_player_feed(player.get(), bad, 4, &consumed, 0) == STHD_CORRUPT_STREAM &&
               consumed == 4,
           "invalid live AU length");
    expect(sthd_player_finish(player.get(), 0) == STHD_CORRUPT_STREAM,
           "fatal stream error is sticky");
    expect(sthd_player_error(player.get())[0] != 0, "player reports error detail");
    player.reset(sthd_player_create(&options, error, sizeof(error)));
    expect(sthd_player_finish(player.get(), 0) == STHD_CORRUPT_STREAM, "empty stream rejected");
    options.struct_size = 1;
    expect(sthd_player_create(&options, error, sizeof(error)) == nullptr,
           "player options ABI size check");
}
void audio_policy_tests() {
#if defined(STHD_TEST_COREAUDIO_MAPS)
    for (auto kind :
         {kAudioFormatProperty_ChannelLayoutForBitmap, kAudioFormatProperty_ChannelLayoutForTag}) {
        UInt32 value = kind == kAudioFormatProperty_ChannelLayoutForBitmap
                           ? 0x63f
                           : kAudioChannelLayoutTag_MPEG_7_1_C,
               size = 0;
        expect(AudioFormatGetPropertyInfo(kind, sizeof(value), &value, &size) == noErr,
               "native channel layout expansion");
        std::vector<uint8_t> bytes(size);
        expect(AudioFormatGetProperty(kind, sizeof(value), &value, &size, bytes.data()) == noErr,
               "native map descriptors");
        auto *ca = reinterpret_cast<AudioChannelLayout *>(bytes.data());
        std::array<uint32_t, 16> labels{};
        for (unsigned i = 0; i < ca->mNumberChannelDescriptions; ++i)
            labels[i] = ca->mChannelDescriptions[i].mChannelLabel;
        STHDLayout converted{};
        expect(sthd_audio::coreaudio_reported_labels(
                   labels.data(), ca->mNumberChannelDescriptions,
                   kind == kAudioFormatProperty_ChannelLayoutForBitmap, converted),
               "bitmap/MPEG actual native labels map to 7.1");
        expect(converted.speakers[4] ==
                       (kind == kAudioFormatProperty_ChannelLayoutForBitmap ? STHD_BL : STHD_SL) &&
                   converted.speakers[6] ==
                       (kind == kAudioFormatProperty_ChannelLayoutForBitmap ? STHD_SL : STHD_BL),
               "CoreAudio physical surround order");
    }
#endif
    const char *device_layouts[] = {"2.0",   "5.1",       "7.1",         "5.1.2",
                                    "5.1.4", "7.1.2",     "7.1.4",       "7.1.6",
                                    "9.1.6", "5.1(back)", "5.1.2(back)", "5.1.4(back)"};
    auto mapping_frame = fixture();
    mapping_frame.presentations = 3;
    for (auto name : device_layouts) {
        STHDLayout actual{};
        sthd_layout_named(name, &actual);
        std::reverse(actual.speakers, actual.speakers + actual.channels);
        expect(sthd_audio::reported_layout_valid(actual),
               "reported multichannel physical order accepted");
        STHDAudioCapabilities device{};
        device.pcm_available = device.pcm_layout_valid = 1;
        device.pcm_channels = actual.channels;
        device.pcm_layout = actual;
        for (auto backend : {STHD_AUDIO_COREAUDIO, STHD_AUDIO_WASAPI, STHD_AUDIO_PIPEWIRE}) {
            device.pcm_backend = backend;
            STHDAudioPlan selected{};
            expect(sthd_audio_plan(&mapping_frame, &device, nullptr, 0, &selected) == STHD_OK &&
                       selected.layout.channels == actual.channels,
                   "auto plan uses actual channel map");
            for (unsigned i = 0; i < actual.channels; ++i)
                expect(selected.layout.speakers[i] == actual.speakers[i],
                       "auto retains physical slot order");
        }
        actual.speakers[1] = actual.speakers[0];
        expect(!sthd_audio::reported_layout_valid(actual), "duplicate device positions rejected");
    }
    STHDLayout windows_map{};
    expect(sthd_audio::wave_mask_layout(8, 0x63f, windows_map) &&
               windows_map.speakers[4] == STHD_BL && windows_map.speakers[6] == STHD_SL,
           "Windows real 7.1 mask ordering");
    expect(sthd_audio::wave_mask_layout(6, 0x60f, windows_map) &&
               windows_map.speakers[4] == STHD_SL,
           "Windows 5.1 side mask");
    expect(sthd_audio::wave_mask_layout(6, 0x3f, windows_map) && windows_map.speakers[4] == STHD_BL,
           "Windows 5.1 back mask");
    expect(!sthd_audio::wave_mask_layout(2, 0, windows_map) &&
               !sthd_audio::wave_mask_layout(2, 0x63f, windows_map),
           "absent/mismatched mask never becomes stereo");
    STHDLayout device_stereo{};
    expect(sthd_audio::preferred_stereo_layout(2, 1, 2, device_stereo) &&
               device_stereo.speakers[0] == STHD_FL && device_stereo.speakers[1] == STHD_FR,
           "authoritative stereo pair");
    expect(sthd_audio::preferred_stereo_layout(2, 2, 1, device_stereo) &&
               device_stereo.speakers[0] == STHD_FR && device_stereo.speakers[1] == STHD_FL,
           "reversed physical stereo pair");
    expect(!sthd_audio::preferred_stereo_layout(2, 1, 1, device_stereo) &&
               !sthd_audio::preferred_stereo_layout(16, 1, 2, device_stereo) &&
               !sthd_audio::preferred_stereo_layout(2, 0, 2, device_stereo),
           "invalid/discrete multichannel stereo inference rejected");
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
    auto waiting = f;
    waiting.positions_valid = 0;
    STHDAudioCapabilities stereo_caps{};
    stereo_caps.pcm_available = stereo_caps.pcm_layout_valid = 1;
    stereo_caps.pcm_channels = 2;
    stereo_caps.pcm_backend = STHD_AUDIO_COREAUDIO;
    sthd_layout_named("2.0", &stereo_caps.pcm_layout);
    expect(sthd_audio_plan(&waiting, &stereo_caps, nullptr, 0, &plan) == STHD_OK &&
               plan.mode == STHD_AUDIO_PCM && plan.layout.channels == 2,
           "core playback remains available while object coordinates preroll");
    stereo_caps.spatial_available = 1;
    stereo_caps.spatial_speaker_mask = 1U << STHD_LFE;
    stereo_caps.max_dynamic_objects = 15;
    expect(sthd_audio_plan(&waiting, &stereo_caps, nullptr, 0, &plan) == STHD_UNKNOWN_LAYOUT,
           "positional output requires known coordinates");
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
    for (const char *name : {"5.1.2", "5.1.4", "5.1.2(back)", "5.1.4(back)"}) {
        STHDLayout extended{};
        sthd_layout_named(name, &extended);
        f.pcm[2][4] = 4194304;
        f.pcm[2][6] = 2097152;
        expect(sthd_render(&f, &five, 1, out.data(), out.size()) == STHD_OK, "base 5.1 reference");
        auto reference = out;
        expect(sthd_render(&f, &extended, 1, out.data(), out.size()) == STHD_OK,
               "silent-height extended bed");
        for (unsigned c = 0; c < 6; ++c)
            expect(out[c] == reference[c], "height extension preserves ground downmix gain");
        for (unsigned c = 6; c < extended.channels; ++c)
            expect(out[c] == 0, "plain bed has no height signal");
        f.pcm[2][4] = f.pcm[2][6] = 0;
    }
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
    {
        std::ifstream header_input(path, std::ios::binary);
        major_header_tests(read_au(header_input));
    }
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
    std::unique_ptr<STHDDecoder, decltype(&sthd_decoder_destroy)> seeking(
        sthd_decoder_create(), sthd_decoder_destroy);
    expect(bool(seeking), "create random-access decoder");
    expect(sthd_decoder_set_strict_pcm_checksum(d, 1) == STHD_OK &&
           sthd_decoder_set_strict_pcm_checksum(seeking.get(), 1) == STHD_OK, "strict stream validation");
    uint64_t seek_base = 0;
    STHDFrame f{};
    std::array<STHDLayout, 9> layouts{};
    for (unsigned i = 0; i < 9; ++i)
        sthd_layout_named(names[i], &layouts[i]);
    double peaks[9]{};
    uint64_t clipped[9]{}, unavailable[9]{};
    double energies[9][16]{};
    uint64_t au = 0, samples = 0;
    while (true) {
        auto bytes = read_au(in);
        if (bytes.empty())
            break;
        auto s = sthd_decode_access_unit(d, bytes.data(), bytes.size(), &f);
        expect(s == STHD_OK, "decode AU " + std::to_string(au) + ": " + sthd_decoder_error(d));
        expect(f.first_sample == samples, "continuous sample timeline");
        if (bytes.size() >= 8 && bytes[4] == 0xf8 && bytes[5] == 0x72 &&
            bytes[6] == 0x6f && bytes[7] == 0xba) {
            sthd_decoder_reset(seeking.get());
            seek_base = samples;
        }
        STHDFrame seek_frame{};
        expect(sthd_decode_access_unit(seeking.get(), bytes.data(), bytes.size(), &seek_frame) ==
                   STHD_OK,
               "decode after major-sync random access");
        expect(seek_frame.first_sample == samples - seek_base, "reset sample timeline");
        expect(seek_frame.sample_rate == f.sample_rate && seek_frame.samples == f.samples &&
                   seek_frame.presentations == f.presentations &&
                   seek_frame.element_channels == f.element_channels &&
                   std::memcmp(f.channels, seek_frame.channels, sizeof(f.channels)) == 0 &&
                   std::memcmp(f.pcm, seek_frame.pcm, sizeof(f.pcm)) == 0,
               "random-access PCM equals continuous decode at AU " + std::to_string(au));
        const uint32_t known_drc = sthd_decoder_drc_valid(seeking.get());
        for (unsigned i = 0; i < f.presentations; ++i)
            if (known_drc & (1U << i))
                expect(f.drc_gain_code[i] == seek_frame.drc_gain_code[i],
                       "available random-access DRC equals continuous decode");
        if (seek_frame.positions_valid)
            expect(f.positions_valid &&
                       std::memcmp(f.positions, seek_frame.positions, sizeof(f.positions)) == 0,
                   "available random-access OAMD equals continuous decode at AU " + std::to_string(au));
        for (unsigned i = 0; i < f.presentations; ++i)
            if (compared & (1U << i))
                compare(refs[i], f.pcm[i], size_t(f.samples) * f.channels[i], au, i);
        for (unsigned i = 0; i < 9; ++i) {
            std::array<float, 640> out{};
            STHDFrameMotion motion{};
            expect(sthd_decoder_motion(d, &motion) == STHD_OK, "stream motion query");
            const auto rendered = sthd_render_motion(&f, &motion, &layouts[i], 1, out.data(), out.size());
            if (rendered == STHD_UNKNOWN_LAYOUT && i >= 3 &&
                motion.valid_samples != ((uint64_t(1) << f.samples) - 1)) {
                unavailable[i] += f.samples;
                continue;
            }
            expect(rendered == STHD_OK, "stream render at AU " + std::to_string(au) + " layout " + names[i]);
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
                  << ",\"peak\":" << peaks[i] << ",\"clipped\":" << clipped[i]
                  << ",\"unavailableSamples\":" << unavailable[i] << ",\"rms\":[";
        for (unsigned c = 0; c < layouts[i].channels; ++c)
            std::cout << (c ? "," : "") << std::sqrt(energies[i][c] / double(std::max<uint64_t>(1, samples - unavailable[i])));
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
void checksum_tests(const std::filesystem::path &path) {
    std::ifstream input(path, std::ios::binary);
    auto *relaxed = sthd_decoder_create(), *strict = sthd_decoder_create();
    expect(relaxed && strict, "checksum decoders");
    expect(sthd_decoder_set_strict_pcm_checksum(strict, 1) == STHD_OK, "enable strict checks");
    STHDFrame a{}, b{};
    std::vector<uint8_t> au;
    for (unsigned n = 0; n < 128; ++n) {
        au = read_au(input);
        expect(sthd_decode_access_unit(relaxed, au.data(), au.size(), &a) == STHD_OK &&
               sthd_decode_access_unit(strict, au.data(), au.size(), &b) == STHD_OK,
               "valid interval before forged checksum");
    }
    au = read_au(input);
    auto damaged = au;
    const size_t directory = 4 + 28;
    size_t payload = directory;
    for (unsigned layer = 0; layer < 3; ++layer) {
        unsigned word = (unsigned(damaged[payload]) << 8) | damaged[payload + 1];
        payload += (word & 0x8000) ? 4 : 2;
    }
    size_t length = (((unsigned(damaged[directory]) << 8) | damaged[directory + 1]) & 0xfff) * 2;
    auto *sub = damaged.data() + payload;
    auto write_bits = [&](unsigned bit, unsigned count, unsigned value) {
        for (unsigned i = 0; i < count; ++i) {
            unsigned at = bit + i, mask = 1U << (7 - (at & 7));
            sub[at / 8] = uint8_t((sub[at / 8] & ~mask) |
                                  (((value >> (count - i - 1)) & 1) ? mask : 0));
        }
    };
    sub[91 / 8] ^= uint8_t(1U << (7 - (91 & 7)));
    write_bits(127, 8, sthd::restart_checksum(sub, 125));
    uint8_t parity = 0;
    for (size_t i = 0; i < length - 2; ++i) parity ^= sub[i];
    sub[length - 2] = parity ^ 0xa9;
    sub[length - 1] = sthd::checksum8(sub, length - 2);
    auto saved = b;
    expect(sthd_decode_access_unit(strict, damaged.data(), damaged.size(), &b) == STHD_CORRUPT_STREAM &&
           !std::memcmp(&saved, &b, sizeof(b)), "strict rejection preserves PCM/state");
    STHDPCMChecksum check{};
    expect(sthd_decoder_pcm_checksum(strict, &check) == STHD_OK && check.total_mismatches == 0,
           "strict rejection preserves checksum counters");
    expect(sthd_decode_access_unit(relaxed, damaged.data(), damaged.size(), &a) == STHD_OK,
           "reported PCM mismatch permits playback");
    expect(sthd_decoder_pcm_checksum(relaxed, &check) == STHD_OK &&
           check.checked_layers == 7 && check.mismatched_layers == 1 && check.total_mismatches == 1 &&
           check.expected[0] != check.actual[0], "copied mismatch evidence");
    expect(sthd_decode_access_unit(strict, au.data(), au.size(), &b) == STHD_OK &&
           !std::memcmp(&a, &b, sizeof(a)), "PCM is unchanged by checksum policy");
    sthd_decoder_reset(relaxed);
    expect(sthd_decoder_pcm_checksum(relaxed, &check) == STHD_OK && check.total_mismatches == 0,
           "reset clears checksum evidence");
    expect(sthd_decoder_set_strict_pcm_checksum(strict, 2) == STHD_INVALID_ARGUMENT,
           "invalid strict policy");
    sthd_decoder_destroy(relaxed); sthd_decoder_destroy(strict);
    std::cout << "PCM checksum report/strict policies and transactional retry: passed\n";
}
void motion_tests(const std::filesystem::path &path) {
    std::ifstream input(path, std::ios::binary);
    std::unique_ptr<STHDDecoder, decltype(&sthd_decoder_destroy)> decoder(
        sthd_decoder_create(), sthd_decoder_destroy);
    expect(bool(input) && bool(decoder), "open timed metadata fixture");
    struct Event { uint64_t sample; unsigned duration; STHDPosition target; };
    const Event events[] = {{0,0,{-1,1,0}}, {58,0,{1,1,0}}, {87,64,{-1,1,1}},
                            {193,512,{1,1,0}}, {273,1536,{-1,-1,0}},
                            {384,73,{1,-1,1}}, {480,0,{-1,1,0}}, {5160,0,{-1,1,0}}};
    unsigned event = 0, duration = 0;
    uint64_t begin = 0, samples = 0;
    STHDPosition from{-1,1,0}, target=from;
    auto evaluate = [&](uint64_t time) {
        double t = duration ? std::min(1.0, double(time-begin)/duration) : 1.0;
        return STHDPosition{float(from.x+(double(target.x)-from.x)*t),
                            float(from.y+(double(target.y)-from.y)*t),
                            float(from.z+(double(target.z)-from.z)*t)};
    };
    auto close = [](STHDPosition a, STHDPosition b) {
        return std::abs(a.x-b.x)<0.000001f && std::abs(a.y-b.y)<0.000001f &&
               std::abs(a.z-b.z)<0.000001f;
    };
    while (true) {
        auto au = read_au(input);
        if (au.empty())
            break;
        STHDFrame frame{};
        expect(sthd_decode_access_unit(decoder.get(), au.data(), au.size(), &frame)==STHD_OK,
               "decode timed OAMD fixture");
        STHDFrameMotion motion{};
        expect(sthd_decoder_motion(decoder.get(), &motion)==STHD_OK && motion.channels==16 &&
                   motion.valid_samples==((uint64_t(1)<<frame.samples)-1), "motion dimensions");
        for (unsigned n=0;n<frame.samples;++n) {
            uint64_t time=samples+n;
            while (event<std::size(events) && events[event].sample==time) {
                from=evaluate(time);
                target=events[event].target;
                begin=time;
                duration=events[event].duration;
                ++event;
            }
            expect(close(motion.positions[n][1],evaluate(time)), "sample-exact ramp/offset");
            expect(close(motion.positions[n][0],{0,1,-1}), "LFE position remains isolated");
        }
        auto damaged=au;
        damaged[damaged.size()/2]^=1;
        auto saved=motion;
        expect(sthd_decode_access_unit(decoder.get(),damaged.data(),damaged.size(),&frame)!=STHD_OK,
               "corrupt timed AU rejected");
        expect(sthd_decoder_motion(decoder.get(),&motion)==STHD_OK &&
                   std::memcmp(&motion,&saved,sizeof(motion))==0,
               "failed AU preserves motion state");
        samples+=frame.samples;
    }
    expect(samples==6417 && event==std::size(events), "complete timed fixture");
    auto frame=fixture();
    STHDFrameMotion motion{};
    motion.samples=40;motion.channels=16;motion.valid_samples=(uint64_t(1)<<40)-1;
    for(unsigned n=0;n<40;++n) {
        std::copy_n(frame.positions,16,motion.positions[n]);
        motion.positions[n][1]=n<18?STHDPosition{-1,1,0}:STHDPosition{1,1,0};
        frame.pcm[3][n*16+1]=4194304;
    }
    std::copy_n(motion.positions[39],16,frame.positions);
    STHDLayout layout{};sthd_layout_named("7.1.4",&layout);
    std::array<float,640> pcm{};
    expect(sthd_render_motion(&frame,&motion,&layout,1,pcm.data(),pcm.size())==STHD_OK,
           "timed renderer");
    for(unsigned n=0;n<40;++n)
        for(unsigned c=0;c<layout.channels;++c)
            expect(std::abs(pcm[n*layout.channels+c]-((c==(n<18?0U:1U))?.5f:0.f))<0.000001f,
                   "renderer does not apply future position early");
    sthd_audio::Ring queue(2,true);
    std::array<float,80> audio{};
    motion.channels=2;
    for(unsigned n=0;n<40;++n)motion.positions[n][1]={-1,1,0};
    expect(queue.push(audio.data(),40,&motion), "queue first PCM/position span");
    for(unsigned n=0;n<40;++n)motion.positions[n][1]={1,1,0};
    expect(queue.push(audio.data(),40,&motion), "queue future PCM/position span");
    STHDPosition positions[2]{};
    expect(queue.pop(audio.data(),40,positions)==40 && positions[1].x==-1,
           "future coordinates cannot overwrite queued PCM");
    expect(queue.pop(audio.data(),40,positions)==40 && positions[1].x==1,
           "next coordinates align with next PCM");
    std::cout<<"timed OAMD: offsets, zero/64/73/512/1536 ramps, future AU, PCM routing, queue: passed\n";
}
} // namespace
int main(int argc, char **argv) {
    try {
        renderer_tests();
        audio_policy_tests();
        player_transport_tests();
        if (argc >= 3 && std::string(argv[1]) == "--stream")
            stream_tests(std::filesystem::u8path(argv[2]), argc >= 4 ? argv[3] : "");
        else if ((argc == 3 || argc == 4) && std::string(argv[1]) == "--generate")
            generate(std::filesystem::u8path(argv[2]), argc == 4 ? argv[3] : "");
        else if (argc==3 && std::string(argv[1])=="--matrix")
            sthd_matrix_syntax_tests(argv[2]);
        else if (argc==3 && std::string(argv[1])=="--checksum")
            checksum_tests(std::filesystem::u8path(argv[2]));
        else if (argc==3 && std::string(argv[1])=="--motion")
            motion_tests(std::filesystem::u8path(argv[2]));
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
