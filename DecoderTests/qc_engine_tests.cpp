// Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later
#include "../Sources/DecoderCLI/macos/QCEngine.hpp"
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>
using namespace sthd_qc;
namespace fs = std::filesystem;
void expect(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
std::vector<uint8_t> bytes(const fs::path &path) {
    std::ifstream in(path, std::ios::binary);
    expect(bool(in), "Cannot read test output");
    return {std::istreambuf_iterator<char>(in), {}};
}
Snapshot wait(Engine &engine, const std::function<bool(const Snapshot &)> &predicate) {
    auto until = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (true) {
        auto s = engine.snapshot(); if (predicate(s)) return s;
        if (std::chrono::steady_clock::now() > until) throw std::runtime_error("QC state timeout: " + s.status);
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
}
int main(int argc, char **argv) try {
    expect(argc == 3, "Expected fixture and output directory");
    fs::create_directories(fs::u8path(argv[2]));
    const auto root = fs::u8path(argv[2]) / ("qc-engine-" + std::to_string(
        std::chrono::steady_clock::now().time_since_epoch().count()));
    expect(!fs::exists(root), "Test output already exists"); fs::create_directory(root);
    const std::string source = argv[1];
    Engine engine; engine.monitor(Monitor::meters); engine.load(source, false);
    auto s = wait(engine, [](const Snapshot &v) { return v.loaded && !v.seeking; });
    expect(s.total > 80, "Fixture is too short"); const auto total = s.total;
    engine.seek(41);
    s = wait(engine, [](const Snapshot &v) { return !v.seeking && v.position == 41; });
    expect(!s.playing, "Seeking paused stream must remain paused");
    for (auto name : {"2.0", "5.1", "7.1", "5.1.2", "5.1.4", "7.1.2", "7.1.4", "7.1.6", "9.1.6"}) {
        engine.layout(name);
        s = wait(engine, [&](const Snapshot &v) { return !v.seeking && v.layoutName == name; });
        expect(s.position == 41, "Layout switch changed playhead");
        engine.solo(int(s.layout.channels - 1));
        expect(engine.snapshot().solo == int(s.layout.channels - 1), "Solo selection failed");
    }
    engine.seek(total);
    wait(engine, [&](const Snapshot &v) { return !v.seeking && v.position == total; });
    engine.toggle();
    s = wait(engine, [](const Snapshot &v) { return v.playing && !v.seeking && v.position > 0; });
    expect(s.position < total, "Replay at EOS failed");
    engine.toggle(); wait(engine, [](const Snapshot &v) { return !v.playing && !v.seeking; });
    engine.stop(); wait(engine, [](const Snapshot &v) { return !v.seeking && v.position == 0; });
    // Superseded loads and seek requests must not publish stale state.
    engine.load(source, false); engine.load(source, false);
    wait(engine, [](const Snapshot &v) { return v.loaded && !v.seeking; });
    engine.seek(40); engine.seek(79);
    wait(engine, [](const Snapshot &v) { return !v.seeking && v.position == 79; });
    engine.beginScrub();
    for (unsigned i = 0; i < 20; ++i) engine.previewScrub(i * 3);
    s = engine.snapshot();
    expect(s.scrubbing && !s.seeking && !s.playing && s.position == 57,
           "scrub preview must defer decoder replay");
    engine.endScrub(41);
    wait(engine, [](const Snapshot &v) { return !v.seeking && !v.scrubbing && v.position == 41; });
    expect(engine.snapshot().checkpointCount <= 128, "checkpoint bound exceeded");
    engine.toggle();
    wait(engine, [](const Snapshot &v) { return v.playing && !v.seeking; });
    engine.beginScrub(); engine.previewScrub(61); engine.endScrub(41);
    wait(engine, [](const Snapshot &v) { return v.playing && !v.seeking && !v.scrubbing; });

    engine.shutdown();
    std::atomic<bool> cancel{false};
    auto path = [&](const char *name) { return (root / name).u8string(); };
    auto a = exportPCM(source, path("24.pcm"), "7.1", Format::s24, cancel);
    auto b = exportPCM(source, path("32.pcm"), "7.1", Format::s32, cancel);
    auto c = exportPCM(source, path("float.pcm"), "7.1", Format::f32, cancel);
    auto d = exportPCM(source, path("wave.wav"), "7.1", Format::wave, cancel);
    expect(a.samples == total && b.samples == total && c.samples == total && d.samples == total, "Export duration differs");
    auto p24 = bytes(path("24.pcm")), p32 = bytes(path("32.pcm")), pf = bytes(path("float.pcm")), wav = bytes(path("wave.wav"));
    expect(p24.size() == total * 8 * 3 && p32.size() == total * 8 * 4, "Raw export length differs");
    expect(wav.size() == p24.size() + 104, "WAVE length differs");
    expect(std::equal(p24.begin(), p24.end(), wav.begin() + 104), "WAVE PCM differs");
    for (size_t i = 0; i < total * 8; ++i) {
        expect(p32[i*4] == 0 && p32[i*4+1] == p24[i*3] && p32[i*4+2] == p24[i*3+1] && p32[i*4+3] == p24[i*3+2], "S32 alignment differs");
        int32_t v = int32_t(uint32_t(p24[i*3]) | uint32_t(p24[i*3+1]) << 8 | uint32_t(p24[i*3+2]) << 16);
        if (v & 0x800000) v -= 0x1000000;
        float f; std::memcpy(&f, pf.data() + i * 4, 4);
        expect(std::abs(double(f) * 8388608 - v) <= .51, "Float export differs");
    }
    bool rejected = false;
    try { exportPCM(source, path("wave.wav"), "7.1", Format::wave, cancel); } catch (...) { rejected = true; }
    expect(rejected && bytes(path("wave.wav")) == wav, "Existing destination was not preserved");
    rejected = false;
    try { exportPCM(source, path("cancel.wav"), "7.1", Format::wave, cancel, [&](uint64_t) { cancel = true; }); } catch (...) { rejected = true; }
    expect(rejected && !fs::exists(path("cancel.wav")) && !fs::exists(path("cancel.wav.channels.json")), "Cancelled output remains");
    cancel = false;
    auto original = bytes(source); auto corrupt = root / "truncated.mlp";
    { std::ofstream out(corrupt, std::ios::binary); out.write(reinterpret_cast<const char *>(original.data()), std::streamsize(original.size() - 1)); }
    rejected = false;
    try { exportPCM(corrupt.u8string(), path("failed.wav"), "7.1", Format::wave, cancel); } catch (...) { rejected = true; }
    expect(rejected && !fs::exists(path("failed.wav")) && !fs::exists(path("failed.wav.channels.json")), "Failed output remains");
    std::cout << "QC seek, replay, layouts, Solo, formats and output lifetime passed\n";
    return 0;
} catch (const std::exception &e) { std::cerr << e.what() << '\n'; return 1; }
