// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include "include/TrueHDDecoder.h"
#include <cstddef>
#include <cstdint>
#include <stdexcept>
namespace sthd {
struct Failure : std::runtime_error {
    STHDStatus status;
    Failure(STHDStatus s, const char *message) : std::runtime_error(message), status(s) {}
};
inline void require(bool condition, const char *message) {
    if (!condition)
        throw Failure(STHD_CORRUPT_STREAM, message);
}
inline void supported(bool condition, const char *message) {
    if (!condition)
        throw Failure(STHD_UNSUPPORTED_STREAM, message);
}
struct Bits {
    const uint8_t *data;
    size_t limit, pos = 0;
    Bits(const uint8_t *p, size_t bytes) : data(p), limit(bytes * 8) {}
    uint32_t read(unsigned count) {
        require(count <= 32 && pos <= limit && count <= limit - pos, "truncated bit field");
        uint32_t v = 0;
        for (unsigned i = 0; i < count; ++i, ++pos)
            v = (v << 1) | ((data[pos / 8] >> (7 - pos % 8)) & 1U);
        return v;
    }
    int32_t signed_read(unsigned count) {
        require(count >= 1 && count <= 31, "invalid signed field width");
        uint32_t v = read(count), sign = 1U << (count - 1);
        return int32_t(int64_t(v ^ sign) - sign);
    }
    void skip(unsigned count) { (void)read(count); }
    void zero(unsigned count) { require(read(count) == 0, "nonzero reserved field"); }
    void align(unsigned bits) {
        while (pos % bits)
            zero(1);
    }
    uint32_t variable(unsigned group) {
        uint64_t v = 0;
        for (unsigned n = 0; n < 5; ++n) {
            v += read(group);
            require(v <= 8190, "metadata variable length overflow");
            if (!read(1))
                return uint32_t(v);
            v = (v + 1) << group;
        }
        throw Failure(STHD_CORRUPT_STREAM, "unterminated metadata length");
    }
};
inline uint16_t be16(const uint8_t *p) { return uint16_t((unsigned(p[0]) << 8) | p[1]); }
inline int64_t floor_shift(int64_t value, unsigned shift) {
    const int64_t scale = int64_t(1) << shift;
    return value >= 0 ? value / scale : -1 - (-(value + 1) / scale);
}
// Bitstream arithmetic wraps at 32 bits; avoid implementation-defined narrowing.
inline int32_t wrap32(int64_t v) {
    const uint32_t u = uint32_t(uint64_t(v));
    return u <= 0x7fffffffU ? int32_t(u) : int32_t(int64_t(u) - 0x100000000LL);
}
uint8_t checksum8(const uint8_t *, size_t);
uint16_t checksum16(const uint8_t *, size_t);
uint8_t restart_checksum(const uint8_t *, size_t);
void authenticate_evolution(const uint8_t *prefix, size_t prefix_bytes, const uint8_t *evolution,
                            size_t bytes, size_t protection_bit, uint8_t expected);
} // namespace sthd
