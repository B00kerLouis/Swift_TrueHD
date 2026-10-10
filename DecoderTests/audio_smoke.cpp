// SPDX-License-Identifier: LGPL-2.1-or-later
#include "TrueHDDecoder.h"
#include <array>
#include <limits>
#include <iostream>
#include <memory>
#include <string>
int main(int argc, char **argv) {
    STHDAudioCapabilities caps{};
    auto status = sthd_audio_capabilities(&caps);
    if (status != STHD_OK) {
        std::cerr << "No native endpoint: " << caps.endpoint << "\n";
        return 77;
    }
    STHDFrame frame{};
    frame.samples = 40;
    frame.sample_rate = 48000;
    frame.presentations = 3;
    frame.channels[0] = 2;
    frame.channels[1] = 6;
    frame.channels[2] = 8;
    STHDLayout explicit_layout{};
    STHDLayout *requested = nullptr;
    if (argc == 2) {
        if (sthd_layout_named(argv[1], &explicit_layout) != STHD_OK)
            return 1;
        requested = &explicit_layout;
    }
    STHDAudioPlan plan{};
    status = sthd_audio_plan(&frame, &caps, requested, 0, &plan);
    if (status != STHD_OK) {
        std::cerr << sthd_status_string(status) << "\n";
        return 2;
    }
    char error[256];
    std::unique_ptr<STHDAudioOutput, decltype(&sthd_audio_close)> out(
        sthd_audio_open(&plan, error, sizeof(error)), sthd_audio_close);
    if (!out) {
        std::cerr << error << "\n";
        return 3;
    }
    // Silence verifies actual native scheduling, channel negotiation, and drain
    // without producing an audible signal on the user's default device.
    std::array<float, 640> pcm{};
    if (sthd_audio_write_pcm(out.get(), pcm.data(), 0, pcm.size(), 0) != STHD_INVALID_ARGUMENT ||
        sthd_audio_write_pcm(out.get(), pcm.data(), 40, 1, 0) != STHD_BUFFER_TOO_SMALL)
        return 7;
    pcm[0] = std::numeric_limits<float>::quiet_NaN();
    if (sthd_audio_write_pcm(out.get(), pcm.data(), 40, pcm.size(), 0) != STHD_INVALID_ARGUMENT)
        return 8;
    pcm[0] = 0;
    for (unsigned i = 0; i < 1200; ++i) {
        status = i & 1 ? sthd_audio_write(out.get(), &frame, 0, 5000)
                       : sthd_audio_write_pcm(out.get(), pcm.data(), 40, pcm.size(), 5000);
        if (status != STHD_OK) {
            std::cerr << sthd_status_string(status) << "\n";
            return 4;
        }
    }
    status = sthd_audio_drain(out.get(), 5000);
    if (status != STHD_OK) {
        std::cerr << sthd_status_string(status) << "\n";
        return 5;
    }
    STHDAudioStats stats{};
    sthd_audio_stats(out.get(), &stats);
    if (stats.submitted_frames != 48000 || stats.consumed_frames != 48000)
        return 6;
    std::cout << sthd_audio_backend_name(plan.backend) << " channels=" << plan.layout.channels
              << " submitted=" << stats.submitted_frames << " consumed=" << stats.consumed_frames
              << " underruns=" << stats.underruns << "\n";
    return 0;
}
