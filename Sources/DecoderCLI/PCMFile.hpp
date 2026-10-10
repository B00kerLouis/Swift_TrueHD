// Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once
#include <array>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <filesystem>
#include <stdexcept>
#include <string>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#include <share.h>
#include <sys/stat.h>
#endif
namespace sthd_cli {
namespace fs = std::filesystem;
inline void fail(const std::string &s) { throw std::runtime_error(s); }
inline FILE *exclusive_file(const fs::path &p) {
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
} // namespace sthd_cli
