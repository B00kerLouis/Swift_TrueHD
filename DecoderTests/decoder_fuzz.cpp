// SPDX-License-Identifier: LGPL-2.1-or-later
#include "TrueHDDecoder.h"
#include <array>
#include <cstdlib>
#include <cstring>

extern "C" size_t LLVMFuzzerMutate(uint8_t *, size_t, size_t);

namespace {
unsigned be16(const uint8_t *p) { return (unsigned(p[0]) << 8) | p[1]; }
uint16_t crc16(const uint8_t *p, size_t bytes) {
    uint16_t value = 0;
    for (size_t i = 0; i + 2 < bytes; ++i) {
        value ^= uint16_t(unsigned(p[i]) << 8);
        for (unsigned bit = 0; bit < 8; ++bit)
            value = uint16_t((unsigned(value) << 1) ^ ((value & 0x8000) ? 0x2d : 0));
    }
    return uint16_t((value >> 8) | (unsigned(value) << 8)) ^
           uint16_t(p[bytes - 2] | (unsigned(p[bytes - 1]) << 8));
}
uint8_t crc8(const uint8_t *p, size_t bytes) {
    uint8_t value = 0x3c;
    for (size_t i = 0; i + 1 < bytes; ++i) {
        value ^= p[i];
        for (unsigned bit = 0; bit < 8; ++bit)
            value = uint8_t((unsigned(value) << 1) ^ ((value & 0x80) ? 0x63 : 0));
    }
    return value ^ p[bytes - 1];
}
// Repair outer checks only after all offsets are bounded. This allows mutated
// seeds to reach prediction/matrix/OAMD code rather than stopping at CRCs.
void seal(uint8_t *p, size_t bytes) {
    if (bytes < 8 || bytes > STHD_MAX_ACCESS_UNIT || (bytes & 1))
        return;
    bool major = std::memcmp(p + 4, "\xf8\x72\x6f\xba", 4) == 0;
    if (!major || bytes < 32)
        return;
    size_t sync = 28;
    if (p[29] & 1) {
        if (bytes < 34)
            return;
        sync += 2 + size_t(p[30] >> 4) * 2;
    }
    if (4 + sync > bytes)
        return;
    unsigned layers = p[20] >> 4;
    if (layers != 3 && layers != 4)
        return;
    std::array<size_t, 4> ends{};
    size_t directory = 4 + sync, at = directory;
    unsigned parity = unsigned(bytes / 2) ^ be16(p + 2);
    for (unsigned i = 0; i < layers; ++i) {
        if (at + 2 > bytes)
            return;
        unsigned word = be16(p + at);
        parity ^= p[at] ^ p[at + 1];
        at += 2;
        ends[i] = (word & 0xfff) * 2;
        if (ends[i] < (i ? ends[i - 1] : 0) + 4)
            return;
        if (word & 0x8000) {
            if (at + 2 > bytes)
                return;
            parity ^= p[at] ^ p[at + 1];
            at += 2;
        }
    }
    if (ends[layers - 1] > bytes - at)
        return;
    uint16_t check = crc16(p + 4, sync - 2);
    p[4 + sync - 2] = uint8_t(check);
    p[4 + sync - 1] = uint8_t(check >> 8);
    for (unsigned i = 0; i < layers; ++i) {
        size_t begin = i ? ends[i - 1] : 0;
        size_t count = ends[i] - begin;
        uint8_t *sub = p + at + begin;
        uint8_t subparity = 0xa9;
        for (size_t j = 0; j + 2 < count; ++j)
            subparity ^= sub[j];
        sub[count - 2] = subparity;
        sub[count - 1] = crc8(sub, count - 2);
    }
    parity ^= parity >> 8;
    parity ^= parity >> 4;
    unsigned header = ((parity ^ 15) & 15) << 12 | unsigned(bytes / 2);
    p[0] = uint8_t(header >> 8);
    p[1] = uint8_t(header);
}
void attempt(STHDDecoder *decoder, const uint8_t *p, size_t bytes) {
    STHDFrame frame;
    std::memset(&frame, 0x5a, sizeof(frame));
    auto saved = frame;
    const uint32_t known_drc = sthd_decoder_drc_valid(decoder);
    auto status = sthd_decode_access_unit(decoder, p, bytes, &frame);
    if (status != STHD_OK) {
        if (std::memcmp(&frame, &saved, sizeof(frame)) ||
            sthd_decoder_drc_valid(decoder) != known_drc)
            std::abort();
        return;
    }
    if (!frame.samples || frame.samples > 40 || frame.sample_rate != 48000 ||
        frame.presentations < 3 || frame.presentations > 4)
        std::abort();
    for (unsigned layer = 0; layer < frame.presentations; ++layer) {
        if (!frame.channels[layer] || frame.channels[layer] > 16)
            std::abort();
        for (unsigned i = 0; i < frame.samples * frame.channels[layer]; ++i)
            if (frame.pcm[layer][i] < -8388608 || frame.pcm[layer][i] > 8388607)
                std::abort();
    }
}
} // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *p, size_t bytes) {
    STHDDecoder *decoder = sthd_decoder_create();
    if (!decoder)
        return 0;
    attempt(decoder, p, bytes);
    sthd_decoder_reset(decoder);
    size_t at = 0;
    for (unsigned units = 0; units < 256 && bytes - at >= 4; ++units) {
        size_t count = (be16(p + at) & 0xfff) * 2;
        if (count < 4 || count > bytes - at)
            break;
        attempt(decoder, p + at, count);
        at += count;
    }
    if (bytes <= STHD_MAX_ACCESS_UNIT) {
        std::array<uint8_t, STHD_MAX_ACCESS_UNIT> normalized{};
        std::memcpy(normalized.data(), p, bytes);
        seal(normalized.data(), bytes);
        sthd_decoder_reset(decoder);
        attempt(decoder, normalized.data(), bytes);
    }
    sthd_decoder_destroy(decoder);
    return 0;
}

extern "C" size_t LLVMFuzzerCustomMutator(uint8_t *p, size_t bytes, size_t maximum,
                                         unsigned seed) {
    size_t result = LLVMFuzzerMutate(p, bytes, maximum);
    if (seed & 1)
        seal(p, result);
    return result;
}
