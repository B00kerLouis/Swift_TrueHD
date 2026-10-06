// SPDX-License-Identifier: LGPL-2.1-or-later
#include "TrueHDDecoder.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
int main(int argc, char **argv) {
    try {
        if (argc < 2 || argc > 3)
            throw std::runtime_error("player_smoke INPUT.mlp [LAYOUT]");
        std::ifstream input(std::filesystem::u8path(argv[1]), std::ios::binary);
        if (!input)
            throw std::runtime_error("cannot open encoded stream");
        STHDPlayerOptions options{};
        options.struct_size = sizeof(options);
        options.gain = 0;
        if (argc == 3) {
            options.explicit_layout = 1;
            if (sthd_layout_named(argv[2], &options.layout) != STHD_OK)
                throw std::runtime_error("invalid layout");
        }
        char error[256];
        std::unique_ptr<STHDPlayer, decltype(&sthd_player_destroy)> player(
            sthd_player_create(&options, error, sizeof(error)), sthd_player_destroy);
        if (!player)
            throw std::runtime_error(error);
        // Exercise transport fragmentation independently of AU boundaries,
        // including one-byte fields, large batches, and zero-timeout retries.
        const size_t sizes[] = {1, 3, 7, 65536, 5, 8191};
        size_t round = 0;
        uint64_t total = 0, timeouts = 0;
        std::array<uint8_t, 65536> buffer{};
        while (true) {
            input.read(reinterpret_cast<char *>(buffer.data()),
                       std::streamsize(sizes[round++ % 6]));
            size_t bytes = size_t(input.gcount());
            if (!bytes)
                break;
            size_t offset = 0;
            do {
                size_t consumed = 0;
                auto status = sthd_player_feed(player.get(), buffer.data() + offset, bytes - offset,
                                               &consumed, 0);
                if (consumed > bytes - offset)
                    throw std::runtime_error("invalid consumption counter");
                offset += consumed;
                total += consumed;
                if (status == STHD_TIMEOUT) {
                    ++timeouts;
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                    continue;
                }
                if (status != STHD_OK)
                    throw std::runtime_error(sthd_player_error(player.get()));
                if (offset == bytes)
                    break;
            } while (true);
        }
        auto status = sthd_player_finish(player.get(), 5000);
        if (status != STHD_OK)
            throw std::runtime_error(sthd_player_error(player.get()));
        STHDPlayerStats stats{};
        sthd_player_stats(player.get(), &stats);
        if (stats.accepted_bytes != total || stats.buffered_bytes || stats.pending_frame ||
            !stats.finished || stats.audio.submitted_frames != stats.decoded_samples ||
            stats.audio.consumed_frames != stats.decoded_samples)
            throw std::runtime_error("streaming counters do not close");
        STHDFrame last{};
        if (sthd_player_last_frame(player.get(), &last) != STHD_OK ||
            last.first_sample + last.samples != stats.decoded_samples)
            throw std::runtime_error("last PCM frame does not match stream timeline");
        size_t consumed = 42;
        if (sthd_player_feed(player.get(), nullptr, 0, &consumed, 0) != STHD_INVALID_ARGUMENT ||
            consumed != 0)
            throw std::runtime_error("finished player accepts more input");
        if (sthd_player_finish(player.get(), 0) != STHD_OK)
            throw std::runtime_error("finish is not idempotent");
        player.reset(sthd_player_create(&options, error, sizeof(error)));
        input.clear();
        input.seekg(0);
        for (unsigned au = 0; au < 80; ++au) {
            std::array<uint8_t, STHD_MAX_ACCESS_UNIT> packet{};
            input.read(reinterpret_cast<char *>(packet.data()), 4);
            if (input.gcount() != 4)
                throw std::runtime_error("cancel test needs at least 80 AUs");
            size_t bytes = ((unsigned(packet[0]) & 15) * 256 + packet[1]) * 2;
            if (bytes < 4 || bytes > packet.size())
                throw std::runtime_error("invalid cancel fixture AU");
            input.read(reinterpret_cast<char *>(packet.data() + 4), std::streamsize(bytes - 4));
            auto result = sthd_player_feed(player.get(), packet.data(), bytes, &consumed, 5000);
            if (result != STHD_OK)
                throw std::runtime_error(sthd_player_error(player.get()));
        }
        auto cancel_started = std::chrono::steady_clock::now();
        std::thread active_cancel([&] {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            sthd_player_cancel(player.get());
        });
        auto cancelled_result = sthd_player_finish(player.get(), 5000);
        active_cancel.join();
        if (cancelled_result != STHD_CANCELLED ||
            std::chrono::steady_clock::now() - cancel_started > std::chrono::milliseconds(500))
            throw std::runtime_error("active drain cancellation is not responsive");
        player.reset(sthd_player_create(&options, error, sizeof(error)));
        std::thread cancel([&] { sthd_player_cancel(player.get()); });
        cancel.join();
        if (sthd_player_feed(player.get(), nullptr, 0, &consumed, 0) != STHD_CANCELLED)
            throw std::runtime_error("cross-thread cancellation failed");
        std::cout << sthd_audio_backend_name(stats.backend) << " realtime bytes=" << total
                  << " AUs=" << stats.decoded_access_units << " decoded=" << stats.decoded_samples
                  << " submitted=" << stats.audio.submitted_frames
                  << " consumed=" << stats.audio.consumed_frames << " timeouts=" << timeouts
                  << " underruns=" << stats.audio.underruns << "\n";
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "FAIL: " << e.what() << "\n";
        return 1;
    }
}
