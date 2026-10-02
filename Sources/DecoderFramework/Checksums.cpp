// SPDX-License-Identifier: AGPL-3.0-only
#include "BitReader.hpp"
#include <array>
#include <vector>
namespace sthd {
static uint32_t swap(uint32_t n) {
    return (n >> 24) | ((n >> 8) & 0xff00) | ((n << 8) & 0xff0000) | (n << 24);
}
static std::array<uint32_t, 256> table(unsigned bits, uint32_t polynomial) {
    std::array<uint32_t, 256> out{};
    for (unsigned i = 0; i < 256; ++i) {
        uint32_t v = i << 24;
        for (int j = 0; j < 8; ++j) {
            bool bit = (v & 0x80000000U) != 0;
            v <<= 1;
            if (bit)
                v ^= polynomial << (32 - bits);
        }
        out[i] = swap(v);
    }
    return out;
}
static const auto c63 = table(8, 0x63), c2d = table(16, 0x2d), c1d = table(8, 0x1d);
static uint32_t crc(const std::array<uint32_t, 256> &t, uint32_t v, const uint8_t *p, size_t n) {
    for (size_t i = 0; i < n; ++i)
        v = t[(v ^ p[i]) & 255] ^ (v >> 8);
    return v;
}
uint8_t checksum8(const uint8_t *p, size_t n) {
    require(n >= 1, "empty CRC input");
    return uint8_t(crc(c63, 0x3c, p, n - 1)) ^ p[n - 1];
}
uint16_t checksum16(const uint8_t *p, size_t n) {
    require(n >= 2, "short CRC input");
    return uint16_t(crc(c2d, 0, p, n - 2)) ^ uint16_t(p[n - 2] | (unsigned(p[n - 1]) << 8));
}
uint8_t restart_checksum(const uint8_t *p, size_t bits) {
    const size_t n = (bits + 2) / 8;
    require(n >= 1, "short restart checksum");
    uint32_t v = p[0] & 0xc0;
    if (n > 1)
        v = crc(c1d, v, p, n - 1);
    v ^= p[n - 1];
    for (size_t i = 0; i < ((bits + 2) & 7); ++i) {
        v <<= 1;
        if (v & 0x100)
            v ^= 0x11d;
        v ^= (p[n] >> (7 - i)) & 1;
    }
    return uint8_t(v);
}
// Self-contained SHA-256 for the encoder's EMDF HMAC. No platform crypto ABI.
static uint32_t rotr(uint32_t x, unsigned n) { return (x >> n) | (x << (32 - n)); }
static std::array<uint8_t, 32> sha256(const std::vector<uint8_t> &input) {
    static constexpr uint32_t k[64] = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2};
    uint32_t h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                     0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    std::vector<uint8_t> b = input;
    const uint64_t length = uint64_t(b.size()) * 8;
    b.push_back(0x80);
    while (b.size() % 64 != 56)
        b.push_back(0);
    for (int i = 7; i >= 0; --i)
        b.push_back(uint8_t(length >> (i * 8)));
    for (size_t base = 0; base < b.size(); base += 64) {
        uint32_t w[64];
        for (unsigned i = 0; i < 16; ++i)
            w[i] = (uint32_t(b[base + i * 4]) << 24) | (uint32_t(b[base + i * 4 + 1]) << 16) |
                   (uint32_t(b[base + i * 4 + 2]) << 8) | b[base + i * 4 + 3];
        for (unsigned i = 16; i < 64; ++i)
            w[i] = w[i - 16] + (rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)) +
                   w[i - 7] + (rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10));
        uint32_t a = h[0], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7], bb = h[1];
        for (unsigned i = 0; i < 64; ++i) {
            uint32_t t1 =
                hh + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + k[i] + w[i];
            uint32_t t2 =
                (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & bb) ^ (a & c) ^ (bb & c));
            hh = g;
            g = f;
            f = e;
            e = d + t1;
            d = c;
            c = bb;
            bb = a;
            a = t1 + t2;
        }
        h[0] += a;
        h[1] += bb;
        h[2] += c;
        h[3] += d;
        h[4] += e;
        h[5] += f;
        h[6] += g;
        h[7] += hh;
    }
    std::array<uint8_t, 32> out{};
    for (unsigned i = 0; i < 32; ++i)
        out[i] = uint8_t(h[i / 4] >> (24 - (i % 4) * 8));
    return out;
}
void authenticate_evolution(const uint8_t *prefix, size_t pn, const uint8_t *ev, size_t en,
                            size_t bit, uint8_t expected) {
    require(bit + 8 <= en * 8, "EMDF authentication field out of bounds");
    static constexpr uint8_t key[32] = {0x2c, 0x16, 0x95, 0x1c, 0x38, 0x23, 0x20, 0x60,
                                        0xd8, 0x97, 0x5a, 0xa6, 0xcb, 0xdc, 0x54, 0x81,
                                        0x31, 0x42, 0xdc, 0x26, 0x9d, 0xcc, 0x5d, 0x43,
                                        0x76, 0x97, 0x20, 0x6c, 0x93, 0x87, 0x1d, 0xe4};
    std::vector<uint8_t> canonical(ev, ev + en);
    for (size_t i = bit; i < bit + 8; ++i)
        canonical[i / 8] &= uint8_t(~(1U << (7 - i % 8)));
    std::vector<uint8_t> inner(64, 0x36), outer(64, 0x5c);
    for (unsigned i = 0; i < 32; ++i) {
        inner[i] ^= key[i] ^ 0x7a;
        outer[i] ^= key[i] ^ 0x7a;
    }
    inner.insert(inner.end(), prefix, prefix + pn);
    inner.insert(inner.end(), canonical.begin(), canonical.end());
    auto hash = sha256(inner);
    outer.insert(outer.end(), hash.begin(), hash.end());
    require(sha256(outer)[0] == expected, "EMDF primary HMAC mismatch");
}
} // namespace sthd
