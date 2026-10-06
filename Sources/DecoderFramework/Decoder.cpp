// SPDX-License-Identifier: LGPL-2.1-or-later
#include "BitReader.hpp"
#include <algorithm>
#include <array>
#include <cstdio>
#include <cstring>
#include <memory>
#include <limits>
#include <new>
#include <string>
#include <vector>
namespace sthd {
struct Channel {
    int offset = 0, book = 0, lsbs = 24, quant = 0, order = 0, shift = 0;
    int iir_order = 0, iir_shift = 0;
    std::array<int32_t, 8> iir_coefficients{}, iir_history{};
    std::array<int32_t, 8> coefficients{}, history{};
};
struct Matrix {
    unsigned output = 0, frac = 14, mask = 0, bypass = 0, dither = 0;
    int coefficient_shift = 0;
    unsigned delta_bits = 0, delta_precision = 0;
    std::array<int32_t, 18> delta{};
    std::array<int32_t, 18> coefficients{};
};
struct Substream {
    bool initialized = false, terminated = false;
    unsigned minimum = 0, maximum = 0, matrix_max = 0, type = 0, block = 8;
    unsigned matrix_count = 0, noise_shift = 0, presence = 255;
    uint32_t noise_seed = 0;
    std::array<Channel, 16> channel{};
    std::array<int, 16> shifts{}, assignments{};
    std::array<Matrix, 16> matrices{};
    uint32_t lossless = 0;
    int drc = 0;
    bool drc_valid = false;
};
struct State {
    STHDPCMChecksum checksum{};
    unsigned presentations = 0;
    unsigned elements = 0;
    uint64_t samples = 0;
    bool positions_valid = false, positions_pending = false;
    std::array<STHDPosition, 16> positions{};
    std::array<STHDPosition, 16> ramp_from{}, ramp_target{};
    uint64_t ramp_start = 0;
    unsigned ramp_duration = 0, pending_count = 0;
    bool positions_dynamic = false, ended = false;
    struct PendingPosition {
        uint64_t sample = 0;
        unsigned duration = 0;
        std::array<STHDPosition, 16> targets{};
    };
    std::array<PendingPosition, 64> pending{};
    std::array<Substream, 4> substreams{};
};
static uint8_t fold32(uint32_t v) {
    v ^= v >> 16;
    v ^= v >> 8;
    return uint8_t(v);
}
static unsigned fold_nibble(unsigned v) {
    v ^= v >> 8;
    v ^= v >> 4;
    return v & 15;
}
// TrueHD dither lookup constants, published in FFmpeg's MLP decoder.
// Copyright (c) 2007-2008 Ian Caulfield; LGPL-2.1-or-later.
static const int8_t dither_values[256] = {
     30,  51,  22,  54,   3,   7,  -4,  38,  14,  55,  46,  81,  22,  58,  -3,   2,
     52,  31,  -7,  51,  15,  44,  74,  30,  85, -17,  10,  33,  18,  80,  28,  62,
     10,  32,  23,  69,  72,  26,  35,  17,  73,  60,   8,  56,   2,   6,  -2,  -5,
     51,   4,  11,  50,  66,  76,  21,  44,  33,  47,   1,  26,  64,  48,  57,  40,
     38,  16, -10, -28,  92,  22, -18,  29, -10,   5, -13,  49,  19,  24,  70,  34,
     61,  48,  30,  14,  -6,  25,  58,  33,  42,  60,  67,  17,  54,  17,  22,  30,
     67,  44,  -9,  50, -11,  43,  40,  32,  59,  82,  13,  49, -14,  55,  60,  36,
     48,  49,  31,  47,  15,  12,   4,  65,   1,  23,  29,  39,  45,  -2,  84,  69,
      0,  72,  37,  57,  27,  41, -15, -16,  35,  31,  14,  61,  24,   0,  27,  24,
     16,  41,  55,  34,  53,   9,  56,  12,  25,  29,  53,   5,  20, -20,  -8,  20,
     13,  28,  -3,  78,  38,  16,  11,  62,  46,  29,  21,  24,  46,  65,  43, -23,
     89,  18,  74,  21,  38, -12,  19,  12, -19,   8,  15,  33,   4,  57,   9,  -8,
     36,  35,  26,  28,   7,  83,  63,  79,  75,  11,   3,  87,  37,  47,  34,  40,
     39,  19,  20,  42,  27,  34,  39,  77,  13,  42,  59,  64,  45,  -1,  32,  37,
     45,  -5,  53,  -6,   7,  36,  50,  23,   6,  32,   9, -21,  18,  71,  27,  52,
    -25,  31,  35,  42,  -1,  68,  63,  52,  26,  43,  66,  37,  41,  25,  40,  70,
};
static int64_t add64(int64_t a, int64_t b) {
    require((b >= 0 && a <= std::numeric_limits<int64_t>::max() - b) ||
                (b < 0 && a >= std::numeric_limits<int64_t>::min() - b),
            "matrix accumulator overflow");
    return a + b;
}
static int64_t multiply64(int64_t value, unsigned factor) {
    if (!factor)
        return 0;
    require(value <= std::numeric_limits<int64_t>::max() / factor &&
                value >= std::numeric_limits<int64_t>::min() / factor,
            "matrix interpolation overflow");
    return value * factor;
}
static int32_t coefficient_value(int32_t value, unsigned shift) {
    const int64_t scaled = int64_t(value) * (int64_t(1) << shift);
    require(scaled >= std::numeric_limits<int32_t>::min() && scaled <= std::numeric_limits<int32_t>::max(),
            "matrix coefficient overflow");
    return int32_t(scaled);
}
static int32_t pcm24(int64_t value) {
    const uint32_t u = uint32_t(uint64_t(value)) & 0xffffff;
    return u < 0x800000 ? int32_t(u) : int32_t(int64_t(u) - 0x1000000);
}
static void restart(Bits &b, Substream &s, unsigned layer, unsigned presentations,
                    STHDPCMChecksum &checksum, bool strict) {
    const size_t start = b.pos;
    supported(start == 2, "restart header outside first block");
    const unsigned type = b.read(14);
    supported(type == (layer == 0 ? 0x31ea : (layer == 3 ? 0x31ec : 0x31eb)),
              "unsupported restart type");
    b.skip(16); // output timing, distinct from AU input scheduling
    const unsigned minimum = b.read(4), maximum = b.read(4), matrix_max = b.read(4);
    const unsigned expected_min[4] = {0, 2, 6, 8}, expected_max[3] = {1, 5, 7};
    supported(minimum == expected_min[layer] && maximum >= minimum && maximum <= 15 &&
                  matrix_max == maximum,
              "unsupported cumulative channel topology");
    if (layer < 3)
        supported(maximum == expected_max[layer], "unsupported core channel topology");
    if (layer == 3)
        supported(maximum == 11 || maximum == 13 || maximum == 15,
                  "unsupported Atmos element count");
    const unsigned noise_shift = b.read(4);
    const uint32_t noise_seed = b.read(23);
    b.skip(4);
    b.skip(5);
    b.skip(5);
    b.skip(5);
    b.zero(1);
    const uint8_t lossless = uint8_t(b.read(8));
    if (s.initialized) {
        checksum.checked_layers |= 1U << layer;
        checksum.expected[layer] = lossless;
        checksum.actual[layer] = fold32(s.lossless);
        if (checksum.actual[layer] != lossless) {
            checksum.mismatched_layers |= 1U << layer;
            ++checksum.total_mismatches;
            if (strict) {
                char message[128];
                std::snprintf(message, sizeof(message),
                              "restart PCM checksum mismatch: layer %u expected %02x actual %02x",
                              layer, unsigned(lossless), unsigned(checksum.actual[layer]));
                throw Failure(STHD_CORRUPT_STREAM, message);
            }
        }
    }
    // After reset/seek the preceding interval is unavailable. Its checksum is
    // not verifiable; restart CRC and all checks on this interval still apply.
    b.skip(1);
    b.skip(15); // high-resolution timing does not change PCM reconstruction
    std::array<int, 16> assignments{};
    unsigned seen = 0;
    for (unsigned c = 0; c <= matrix_max; ++c) {
        unsigned a = b.read(6);
        require(a <= matrix_max && !(seen & (1U << a)), "invalid channel assignment permutation");
        seen |= 1U << a;
        // FBA core speaker IDs follow side-before-back order. WAVE follows
        // ascending channel-mask bits, which put back-before-side.
        static const unsigned wave_order[8] = {0, 1, 2, 3, 6, 7, 4, 5};
        assignments[c] = int(layer == 2 ? wave_order[a] : a);
    }
    const uint8_t expected = restart_checksum(b.data + start / 8, b.pos - start);
    require(b.read(8) == expected, "restart header CRC mismatch");
    const int drc = s.drc;
    const bool drc_valid = s.drc_valid;
    s = Substream{};
    s.drc = drc;
    s.drc_valid = drc_valid;
    s.initialized = true;
    s.type = type;
    s.noise_shift = noise_shift;
    s.noise_seed = noise_seed;
    s.minimum = minimum;
    s.maximum = maximum;
    s.matrix_max = matrix_max;
    s.assignments = assignments;
    (void)presentations;
}
// Quantization applies to prediction and matrix output, before bypassed bits.
static int32_t quantized(int32_t value, unsigned bits) {
    return wrap32(int64_t(uint32_t(value) & (0xffffffffU << bits)));
}
static void filter(Bits &b, Channel &c, bool iir = false) {
    if (!b.read(1))
        return;
    int &order = iir ? c.iir_order : c.order;
    int &precision = iir ? c.iir_shift : c.shift;
    auto &coefficients = iir ? c.iir_coefficients : c.coefficients;
    auto &history = iir ? c.iir_history : c.history;
    order = int(b.read(4));
    require(order <= (iir ? 4 : 8), "invalid prediction filter order");
    if (!order)
        return;
    precision = int(b.read(4));
    const unsigned bits = b.read(5), shift = b.read(3);
    require(bits >= 1 && bits <= 16 && bits + shift <= 16, "invalid filter coefficient precision");
    for (int i = 0; i < order; ++i)
        coefficients[size_t(i)] = b.signed_read(bits) * int32_t(1U << shift);
    if (b.read(1)) {
        require(iir, "explicit FIR state is forbidden");
        const unsigned state_bits = b.read(4), state_shift = b.read(4);
        for (int i = 0; i < order; ++i)
            history[size_t(i)] = state_bits ? b.signed_read(state_bits) * int32_t(1U << state_shift) : 0;
    }
}
// Wire fractions/shifts are normalized to Q18; interpolation uses the same basis.
static void matrices(Bits &b, Substream &s) {
    if (s.type != 0x31ec) {
        s.matrix_count = b.read(4);
        require(s.matrix_count <= 8, "too many primitive matrices");
        for (unsigned i = 0; i < s.matrix_count; ++i) {
            auto &m = s.matrices[i];
            m = Matrix{};
            m.output = b.read(4);
            m.frac = b.read(4);
            require(m.frac <= 14 && m.output <= s.matrix_max, "invalid primitive matrix configuration");
            m.bypass = b.read(1);
            const unsigned input_max = s.matrix_max + (s.type == 0x31ea ? 2 : 0);
            for (unsigned c = 0; c <= input_max; ++c)
                if (b.read(1)) {
                    m.mask |= 1U << c;
                    m.coefficients[c] = coefficient_value(b.signed_read(m.frac + 2), 18 - m.frac);
                }
            if (s.type == 0x31eb)
                m.dither = b.read(4);
        }
        return;
    }
    if (b.read(1)) {
        if (b.read(1)) {
            s.matrix_count = b.read(4) + 1;
            for (unsigned i = 0; i < s.matrix_count; ++i) {
                auto &m = s.matrices[i];
                // Matrix and delta configurations have independent lifetimes.
                const auto previous_delta = m.delta;
                const auto previous_bits = m.delta_bits, previous_precision = m.delta_precision;
                m = Matrix{};
                m.delta = previous_delta;
                m.delta_bits = previous_bits;
                m.delta_precision = previous_precision;
                m.output = b.read(4);
                m.frac = b.read(4);
                m.coefficient_shift = int(b.read(3)) - 1;
                m.bypass = b.read(2);
                m.dither = b.read(4);
                m.mask = b.read(s.matrix_max + 1);
                require(m.frac <= 14 && m.output <= s.matrix_max, "invalid extended matrix configuration");
            }
        }
        require(s.matrix_count > 0, "extended matrix coefficients without configuration");
        for (unsigned i = 0; i < s.matrix_count; ++i) {
            auto &m = s.matrices[i];
            for (unsigned c = 0; c <= s.matrix_max; ++c)
                m.coefficients[c] = (m.mask & (1U << c))
                    ? coefficient_value(b.signed_read(m.frac + 2), unsigned(18 + m.coefficient_shift - int(m.frac))) : 0;
        }
    }
    if (b.read(1)) {
        require(s.matrix_count > 0, "matrix interpolation without configuration");
        if (b.read(1)) {
            if (b.read(1))
                for (unsigned i = 0; i < s.matrix_count; ++i) {
                    auto &m = s.matrices[i];
                    m.delta_bits = b.read(4);
                    m.delta_precision = b.read(2);
                }
            for (unsigned i = 0; i < s.matrix_count; ++i) {
                auto &m = s.matrices[i];
                for (unsigned c = 0; c <= s.matrix_max; ++c)
                    m.delta[c] = m.delta_bits && (m.mask & (1U << c))
                        ? coefficient_value(b.signed_read(m.delta_bits + 1),
                            unsigned(18 + m.coefficient_shift - int(m.frac) - int(m.delta_precision))) : 0;
            }
        }
    } else {
        for (unsigned i = 0; i < s.matrix_count; ++i)
            s.matrices[i].delta.fill(0);
    }
}
static void parameters(Bits &b, Substream &s) {
    if ((s.presence & 1) && b.read(1))
        s.presence = b.read(8);
    if ((s.presence & 128) && b.read(1))
        s.block = b.read(9);
    require(s.block >= 8 && s.block <= 40, "invalid audio block size");
    if ((s.presence & 64) && b.read(1))
        matrices(b, s);
    if ((s.presence & 32) && b.read(1))
        for (unsigned c = 0; c <= s.matrix_max; ++c)
            s.shifts[c] = b.signed_read(4);
    if ((s.presence & 16) && b.read(1))
        for (unsigned c = 0; c <= s.maximum; ++c)
            s.channel[c].quant = int(b.read(4));
    for (unsigned c = s.minimum; c <= s.maximum; ++c)
        if (b.read(1)) {
            auto &p = s.channel[c];
            if (s.presence & 8)
                filter(b, p);
            if (s.presence & 4)
                filter(b, p, true);
            require(p.order + p.iir_order <= 8, "combined filter order exceeds eight");
            require(!p.order || !p.iir_order || p.shift == p.iir_shift,
                    "FIR/IIR precision mismatch");
            if ((s.presence & 2) && b.read(1))
                p.offset = b.signed_read(15);
            p.book = int(b.read(2));
            p.lsbs = int(b.read(5));
        }
    for (unsigned c = s.minimum; c <= s.maximum; ++c) {
        const auto &p = s.channel[c];
        require(p.lsbs >= p.quant && p.lsbs <= (s.type == 0x31ec ? 31 : 24),
                "invalid Huffman/quantization precision");
    }
}
static int32_t residual(Bits &b, const Channel &p) {
    // Fixed MLP codebooks. Index, rather than a signed symbol, is transmitted.
    static constexpr unsigned codes[3][18] = {
        {1, 1, 1, 1, 1, 1, 1, 4, 5, 6, 7, 3, 5, 9, 17, 33, 65, 129},
        {1, 1, 1, 1, 1, 1, 1, 2, 3, 3, 5, 9, 17, 33, 65, 129, 0, 0},
        {1, 1, 1, 1, 1, 1, 1, 1, 3, 5, 9, 17, 33, 65, 129, 0, 0, 0}};
    static constexpr unsigned lengths[3][18] = {
        {9, 8, 7, 6, 5, 4, 3, 3, 3, 3, 3, 3, 4, 5, 6, 7, 8, 9},
        {9, 8, 7, 6, 5, 4, 3, 2, 2, 3, 4, 5, 6, 7, 8, 9, 0, 0},
        {9, 8, 7, 6, 5, 4, 3, 1, 3, 4, 5, 6, 7, 8, 9, 0, 0, 0}};
    int index = 0;
    if (p.book) {
        unsigned code = 0;
        bool found = false;
        for (unsigned n = 1; n <= 9 && !found; ++n) {
            code = (code << 1) | b.read(1);
            for (unsigned i = 0; i < 18; ++i)
                if (lengths[p.book - 1][i] == n && codes[p.book - 1][i] == code) {
                    index = int(i);
                    found = true;
                    break;
                }
        }
        require(found, "invalid Huffman symbol");
    }
    const int lsbs = p.lsbs - p.quant;
    const int sign = lsbs + (p.book ? 2 - p.book : -1);
    int64_t offset = p.offset;
    if (p.book)
        offset -= int64_t(7) << lsbs;
    if (sign >= 0)
        offset -= int64_t(1) << sign;
    return wrap32((offset + (int64_t(index) << lsbs) + b.read(unsigned(lsbs))) * (int64_t(1) << p.quant));
}
static unsigned decode_substream(const uint8_t *p, size_t bytes, Substream &s, unsigned layer,
                                 unsigned presentations, STHDPCMChecksum &checksum, bool strict,
                                 std::array<std::array<int32_t, 16>, 40> &raw, STHDFrame &out) {
    require(bytes >= 4, "short audio substream");
    uint8_t parity = 0;
    for (size_t i = 0; i < bytes - 1; ++i)
        parity ^= p[i];
    require(parity == 0xa9, "audio substream parity mismatch");
    require(checksum8(p, bytes - 2) == p[bytes - 1], "audio substream CRC mismatch");
    Bits b(p, bytes - 2);
    unsigned at = 0;
    std::array<int32_t, 64> dither{};
    std::array<std::array<unsigned, 16>, 40> bypass{};
    for (unsigned blocks = 0; blocks < 5; ++blocks) {
        if (b.read(1)) {
            if (b.read(1))
                restart(b, s, layer, presentations, checksum, strict);
            if (!s.initialized)
                throw Failure(STHD_NEED_RESTART, "audio parameters require a restart");
            parameters(b, s);
        }
        require(s.initialized && at + s.block <= 40, "audio blocks exceed access unit");
        if (!at && s.type != 0x31ea)
            for (auto &value : dither) {
                const unsigned index = (s.noise_seed >> 15) & 255;
                value = dither_values[index];
                s.noise_seed = ((s.noise_seed << 8) ^ index ^ (index << 5)) & 0x7fffff;
            }
        for (unsigned f = at; f < at + s.block; ++f) {
            for (unsigned i = 0; i < s.matrix_count; ++i)
                bypass[f][i] = b.read(s.matrices[i].bypass);
            for (unsigned c = s.minimum; c <= s.maximum; ++c) {
                auto &ch = s.channel[c];
                int64_t prediction = 0;
                for (int i = 0; i < ch.order; ++i)
                    prediction += int64_t(ch.coefficients[size_t(i)]) * ch.history[size_t(i)];
                for (int i = 0; i < ch.iir_order; ++i)
                    prediction += int64_t(ch.iir_coefficients[size_t(i)]) * ch.iir_history[size_t(i)];
                const unsigned precision = unsigned(ch.order ? ch.shift : ch.iir_shift);
                const int64_t predicted = floor_shift(prediction, precision);
                const int32_t value = quantized(wrap32(int64_t(residual(b, ch)) + predicted), unsigned(ch.quant));
                for (unsigned i = 7; i > 0; --i)
                    ch.history[i] = ch.history[i - 1];
                for (unsigned i = 7; i > 0; --i)
                    ch.iir_history[i] = ch.iir_history[i - 1];
                ch.iir_history[0] = wrap32(int64_t(value) - predicted);
                ch.history[0] = value;
                raw[f][c] = value;
            }
        }
        // Every presentation starts from the unmodified shared transport basis.
        // Primitive rows are sequential and may depend on preceding rows.
        for (unsigned f = at; f < at + s.block; ++f) {
            std::array<int32_t, 18> v{};
            std::copy(raw[f].begin(), raw[f].end(), v.begin());
            unsigned input_max = s.matrix_max;
            if (s.type == 0x31ea) {
                const uint32_t seed = s.noise_seed;
                const unsigned a = (seed >> 15) & 255, b = (seed >> 7) & 255;
                v[s.matrix_max + 1] = (a < 128 ? int32_t(a) : int32_t(a) - 256) * int32_t(1U << s.noise_shift);
                v[s.matrix_max + 2] = (b < 128 ? int32_t(b) : int32_t(b) - 256) * int32_t(1U << s.noise_shift);
                const uint32_t shifted = uint16_t(seed >> 7);
                s.noise_seed = ((seed << 16) ^ shifted ^ (shifted << 5)) & 0x7fffff;
                input_max += 2;
            }
            for (unsigned i = 0; i < s.matrix_count; ++i) {
                const auto &m = s.matrices[i];
                int64_t sum = 0, delta = 0;
                for (unsigned c = 0; c <= input_max; ++c) {
                    sum = add64(sum, int64_t(v[c]) * m.coefficients[c]);
                    delta = add64(delta, int64_t(v[c]) * m.delta[c]);
                }
                if (m.dither) {
                    const unsigned index = ((s.matrix_count - i) * (2 * f + 1) + f) & 63;
                    sum = add64(sum, int64_t(dither[index]) * (int64_t(1) << (11 + m.dither)));
                }
                if (s.type == 0x31ec)
                    sum = add64(sum, multiply64(floor_shift(delta, 18), f * ((65536 / 40) * 4)));
                v[m.output] = wrap32(int64_t(quantized(wrap32(floor_shift(sum, 18)),
                    unsigned(s.channel[m.output].quant))) + bypass[f][i]);
            }
            for (unsigned c = 0; c <= s.matrix_max; ++c) {
                int32_t value = pcm24(s.shifts[c] >= 0 ? int64_t(v[c]) * (int64_t(1) << s.shifts[c])
                                                       : floor_shift(v[c], unsigned(-s.shifts[c])));
                out.pcm[layer][f * (s.matrix_max + 1) + unsigned(s.assignments[c])] = value;
            }
        }
        at += s.block;
        if (b.read(1))
            break;
    }
    require(at == 40, "access unit does not contain 40 PCM samples");
    if (s.type == 0x31ec)
        for (unsigned i = 0; i < s.matrix_count; ++i)
            for (unsigned c = 0; c <= s.matrix_max; ++c) {
                auto &m = s.matrices[i];
                const int64_t next = int64_t(m.coefficients[c]) + m.delta[c];
                require(next >= std::numeric_limits<int32_t>::min() && next <= std::numeric_limits<int32_t>::max(),
                        "interpolated matrix coefficient overflow");
                m.coefficients[c] = int32_t(next);
            }
    b.align(16);
    unsigned trim = 0;
    if (b.pos < b.limit) {
        require(b.limit - b.pos == 32 && b.read(16) == 0xd234, "invalid end-of-stream marker");
        unsigned word = b.read(16);
        if ((word & 0xe000) == 0xe000) {
            trim = word & 0x1fff;
            require(trim < 40, "invalid final PCM trim count");
        } else {
            require(word == 0xd234, "invalid stream termination suffix");
        }
        s.terminated = true;
    }
    require(b.pos == b.limit, "unexpected audio payload tail");
    out.channels[layer] = s.matrix_max + 1;
    // Lossless check is evaluated in matrix-channel order before ch_assign.
    for (unsigned f = 0; f < 40 - trim; ++f)
        for (unsigned c = 0; c <= s.matrix_max; ++c) {
            s.lossless ^=
                (uint32_t(out.pcm[layer][f * (s.matrix_max + 1) + unsigned(s.assignments[c])]) &
                 0xffffffU)
                << (c & 7);

        }
    return trim;
}
static void oamd(Bits &b, State &s, unsigned channels, STHDFrameMotion &motion) {
    supported(b.read(2) == 0, "unsupported OAMD version");
    require(b.read(5) + 1 == channels, "OAMD element count mismatch");
    supported(b.read(1) == 1 && b.read(1) == 1 && b.read(1) == 0, "unsupported OAMD bed structure");
    supported(b.read(4) == 1 && b.read(4) == 1, "unsupported OAMD element list");
    const unsigned bytes = b.variable(4) + 1;
    const size_t end = b.pos + size_t(bytes) * 8;
    require(end <= b.limit, "OAMD object element exceeds payload");
    supported(b.read(1) == 0, "discarded object element unsupported");
    unsigned mode = b.read(2);
    unsigned offset = 0;
    if (mode == 1)
        offset = std::array<unsigned, 4>{8, 16, 18, 24}[b.read(2)];
    else if (mode == 2)
        offset = b.read(5);
    else
        supported(mode == 0, "unsupported OAMD sample offset");
    supported(b.read(3) == 0, "multiple OAMD object blocks unsupported");
    offset += b.read(6) * 32;
    unsigned ramp = b.read(2);
    unsigned duration = std::array<unsigned, 4>{0, 512, 1536, 0}[ramp];
    if (ramp == 3) {
        static constexpr unsigned durations[16] = {
            32, 64, 128, 256, 320, 480, 1000, 1001,
            1024, 1600, 1601, 1602, 1920, 2000, 2002, 2048};
        duration = b.read(1) ? durations[b.read(4)] : b.read(11);
    }
    supported(b.read(1) == 1, "reserved OAMD object data unsupported");
    std::array<STHDPosition, 16> positions{};
    positions[0] = {0, 1, -1};
    for (unsigned c = 0; c < channels; ++c) {
        supported(b.read(1) == 0, "inactive OAMD element unsupported");
        const unsigned gain_mode = b.read(2);
        supported(gain_mode == 0 || gain_mode == 3, "non-unity OAMD gain unsupported");
        supported(b.read(1) == 1, "nondefault OAMD priority unsupported");
        if (c) {
            const unsigned x = b.read(6), y = b.read(6), sign = b.read(1), z = b.read(4);
            positions[c] = {float(std::min(x, 62U)) / 31.0f - 1.0f,
                            1.0f - float(std::min(y, 62U)) / 31.0f,
                            (sign ? 1.0f : -1.0f) * float(z) / 15.0f};
            supported(b.read(1) == 0 && b.read(3) == 0 && b.read(1) == 1 && b.read(2) == 0 &&
                          b.read(1) == 0 && b.read(1) == 0,
                      "unsupported OAMD distance/zone/size/screen/snap");
        }
        supported(b.read(1) == 0, "additional OAMD table data unsupported");
    }
    require(s.pending_count < s.pending.size(), "too many pending OAMD updates");
    State::PendingPosition update{};
    update.sample = s.samples + offset;
    update.duration = duration;
    update.targets = positions;
    unsigned index = s.pending_count++;
    while (index && s.pending[index - 1].sample > update.sample) {
        s.pending[index] = s.pending[index - 1];
        --index;
    }
    s.pending[index] = update;
    motion.update_count = 1;
    motion.updates[0].sample_offset = offset;
    motion.updates[0].ramp_samples = duration;
    std::copy(positions.begin(), positions.end(), motion.updates[0].targets);
    while (b.pos < end)
        b.zero(1);
    require(b.pos == end, "OAMD object length mismatch");
    while (b.pos < b.limit)
        b.zero(1);
}
static void evolution(const uint8_t *au, size_t prefix, size_t bytes, State &s, unsigned channels,
                      STHDFrameMotion &motion) {
    const uint8_t *p = au + prefix;
    require(bytes >= 6 && (bytes & 1) == 0, "truncated Evolution metadata");
    require(fold_nibble(unsigned(p[0]) ^ p[1]) == 15, "Evolution length parity mismatch");
    require(size_t(be16(p) & 0xfff) * 2 + 2 == bytes, "Evolution wrapper length mismatch");
    uint8_t parity = 0;
    for (size_t i = 2; i < bytes; ++i)
        parity ^= p[i];
    require(parity == 0xa9, "Evolution protected-section parity mismatch");
    const size_t en = be16(p + 2) & 0xfff;
    require(en > 0 && 4 + en < bytes, "Evolution payload length mismatch");
    for (size_t i = 4 + en; i < bytes - 1; ++i)
        require(p[i] == 0, "nonzero Evolution padding");
    Bits e(p + 4, en);
    supported(e.read(2) == 0 && e.read(3) == 0 && e.read(5) == 11,
              "unsupported EMDF version/key/payload");
    supported(e.read(1) == 0 && e.read(1) == 0 && e.read(1) == 0 && e.read(1) == 1 &&
                  e.read(8) == 8,
              "unsupported EMDF timing/group/codec data");
    supported(e.read(1) == 0 && e.read(1) == 1 && e.read(1) == 0 && e.read(1) == 0 &&
                  e.read(5) == 0 && e.read(2) == 0,
              "unsupported EMDF payload flags");
    const size_t n = e.variable(8);
    require(n > 0 && n * 8 <= e.limit - e.pos, "EMDF OAMD length exceeds payload");
    std::vector<uint8_t> payload(n);
    for (auto &v : payload)
        v = uint8_t(e.read(8));
    Bits ob(payload.data(), n);
    oamd(ob, s, channels, motion);
    require(e.read(5) == 0, "missing EMDF payload terminator");
    supported(e.read(2) == 1 && e.read(2) == 0, "unsupported EMDF protection lengths");
    const size_t protection = e.pos;
    const uint8_t expected = uint8_t(e.read(8));
    authenticate_evolution(au, prefix, p + 4, en, protection, expected);
    while (e.pos < e.limit)
        e.zero(1);
}
/** Parse the actual major-sync length and validate the supported channel profile. */
static size_t major_sync(State &s, const uint8_t *p, size_t bytes) {
    require(bytes >= 28, "truncated major sync");
    supported(p[3] == 0xba, "MLP/non-FBA stream unsupported");
    const bool extension = (p[25] & 1) != 0;
    unsigned extensions = 0;
    if (extension) {
        require(bytes >= 30, "truncated major-sync extension length");
        extensions = p[26] >> 4;
    }
    const size_t size = 28 + (extension ? 2 + size_t(extensions) * 2 : 0);
    require(bytes >= size, "truncated extended major sync");
    require(checksum16(p, size - 2) ==
                uint16_t(p[size - 2] | (unsigned(p[size - 1]) << 8)),
            "major sync CRC mismatch");

    Bits h(p, size - 2);
    require(h.read(32) == 0xf8726fba, "invalid major sync signature");
    supported(h.read(4) == 0, "only 48 kHz profile supported");
    supported(h.read(4) == 0, "unsupported multichannel type");
    const unsigned modifier0 = h.read(2), modifier1 = h.read(2);
    const unsigned layout1 = h.read(5), modifier2 = h.read(2), layout2 = h.read(13);
    supported(modifier0 == 0 && modifier1 == 1 && modifier2 == 0 &&
                  layout1 == 0x0f && layout2 == 0x04f,
              "unsupported major-sync channel arrangement/modifier");
    require(h.read(16) == 0xb752, "invalid major sync format signature");
    const unsigned flags = h.read(16);
    supported((flags & ~0x1000U) == 0, "unsupported major-sync format flags");
    h.skip(16);
    h.skip(16); // VBR flag and peak rate do not change decoded PCM.
    const unsigned presentations = h.read(4);
    h.zero(2);
    const unsigned extended_info = h.read(2), substream_info = h.read(8);
    supported(presentations == 3 || presentations == 4,
              "unsupported major-sync substream count");
    const bool immersive = presentations == 4;
    supported(extended_info == (immersive ? 3U : 0U) &&
                  substream_info == (immersive ? 0xfcU : 0x3cU),
              "unsupported major-sync presentation flags");
    supported(extension == immersive && (!extension || extensions == 1),
              "unsupported major-sync extension configuration");
    supported(((flags & 0x1000) != 0) == immersive,
              "unsupported major-sync Evolution flag");
    unsigned elements = 0;
    if (extension) {
        h.skip(32);
        h.skip(32); // Remaining fixed channel-meaning/DRC fields.
        require(h.read(4) == extensions, "major-sync extension count mismatch");
        h.skip(11); // Dialogue normalization and mix level.
        elements = h.read(5) + 1;
        supported(elements == 12 || elements == 14 || elements == 16,
                  "unsupported major-sync element count");
        supported(h.read(1) == 1 && h.read(1) == 1 && h.read(10) == 0,
                  "unsupported major-sync object/bed configuration");
    }
    if (s.presentations)
        supported(s.presentations == presentations && s.elements == elements,
                  "presentation topology changed midstream");
    s.presentations = presentations;
    s.elements = elements;
    return size;
}

/** Evaluate an active ramp at the PCM sample's stream-relative time. */
static void position_at(State &s, uint64_t sample) {
    if (!s.positions_valid) {
        // A target is known after seek, but its missing ramp origin is not.
        if (!s.positions_pending || sample < s.ramp_start + s.ramp_duration)
            return;
        s.positions_valid = true;
        s.positions_pending = false;
    }
    double fraction = s.ramp_duration
                          ? std::min(1.0, double(sample - s.ramp_start) / s.ramp_duration)
                          : 1.0;
    for (unsigned c = 0; c < s.elements; ++c) {
        const auto &a = s.ramp_from[c], &b = s.ramp_target[c];
        s.positions[c] = {float(a.x + (double(b.x) - a.x) * fraction),
                          float(a.y + (double(b.y) - a.y) * fraction),
                          float(a.z + (double(b.z) - a.z) * fraction)};
    }
}
/** Apply timed updates before their corresponding PCM samples, across AUs. */
static void motion_frame(State &s, STHDFrameMotion &motion, unsigned samples) {
    motion.samples = samples;
    motion.channels = s.elements;
    motion.first_sample = s.samples;
    for (unsigned n = 0; n < samples && s.elements; ++n) {
        const uint64_t sample = s.samples + n;
        position_at(s, sample);
        while (s.pending_count && s.pending[0].sample <= sample) {
            const auto update = s.pending[0];
            for (unsigned i = 1; i < s.pending_count; ++i)
                s.pending[i - 1] = s.pending[i];
            --s.pending_count;
            const bool previous_known = s.positions_valid;
            if (previous_known) {
                for (unsigned c = 0; c < s.elements; ++c) {
                    const auto &a = s.positions[c], &b = update.targets[c];
                    if (a.x != b.x || a.y != b.y || a.z != b.z)
                        s.positions_dynamic = true;
                }
                s.ramp_from = s.positions;
            } else {
                s.ramp_from = update.targets;
            }
            s.ramp_target = update.targets;
            s.ramp_start = update.sample;
            s.ramp_duration = update.duration;
            s.positions_valid = previous_known || update.duration == 0;
            s.positions_pending = !s.positions_valid;
            position_at(s, sample);
        }
        if (s.positions_valid) {
            motion.valid_samples |= uint64_t(1) << n;
            std::copy(s.positions.begin(), s.positions.end(), motion.positions[n]);
        }
    }
    motion.positions_dynamic = s.positions_dynamic;
}
static void decode(State &s, const uint8_t *p, size_t n, STHDFrame &out,
                   STHDFrameMotion &motion, bool strict) {
    s.checksum.checked_layers = s.checksum.mismatched_layers = 0;
    require(!s.ended, "access unit after end of stream");
    require(n >= 4 && n <= STHD_MAX_ACCESS_UNIT && !(n & 1), "invalid access unit size");
    require(size_t(be16(p) & 0xfff) * 2 == n, "access unit length mismatch");
    size_t directory = 4;
    bool major = n >= 8 && p[4] == 0xf8 && p[5] == 0x72 && p[6] == 0x6f;
    if (major)
        directory += major_sync(s, p + 4, n - 4);
    if (!s.presentations)
        throw Failure(STHD_NEED_RESTART, "stream must start at major sync");
    std::array<size_t, 4> ends{};
    unsigned parity = unsigned(be16(p)) ^ be16(p + 2);
    size_t at = directory;
    for (unsigned i = 0; i < s.presentations; ++i) {
        require(at + 2 <= n, "truncated substream directory");
        const unsigned word = be16(p + at);
        parity ^= p[at] ^ p[at + 1];
        at += 2;
        ends[i] = (word & 0xfff) * 2;
        require(ends[i] > (i ? ends[i - 1] : 0), "unordered substream directory");
        supported((word & 0x2000) != 0, "unprotected substream unsupported");
        require(((word & 0x4000) == 0) == major, "restart/directory flag mismatch");
        if (word & 0x8000) {
            require(at + 2 <= n, "truncated DRC word");
            const unsigned drc = be16(p + at);
            parity ^= p[at] ^ p[at + 1];
            at += 2;
            require((drc & 15) == 0, "nonzero DRC reserved bits");
            s.substreams[i].drc = int((drc >> 7) & 0x1ff);
            s.substreams[i].drc_valid = true;
            if (s.substreams[i].drc & 0x100)
                s.substreams[i].drc -= 512;
        }
    }
    require(fold_nibble(parity) == 15, "access header parity mismatch");
    require(ends[s.presentations - 1] <= n - at, "substream extends beyond access unit");
    std::array<std::array<int32_t, 16>, 40> raw{};
    unsigned trimmed = 0;
    for (unsigned i = 0; i < s.presentations; ++i) {
        size_t begin = i ? ends[i - 1] : 0;
        unsigned trim = 0;
        try {
            trim = decode_substream(p + at + begin, ends[i] - begin, s.substreams[i], i,
                                    s.presentations, s.checksum, strict, raw, out);
        } catch (const Failure &e) {
            const auto message = "layer " + std::to_string(i) + ": " + e.what();
            throw Failure(e.status, message.c_str());
        }
        if (i) {
            require(trim == trimmed, "presentation PCM trim counts disagree");
            require(s.substreams[i].terminated == s.substreams[0].terminated,
                    "presentation termination markers disagree");
        }
        trimmed = trim;
        out.drc_gain_code[i] = s.substreams[i].drc;
    }
    const size_t tail = at + ends[s.presentations - 1];
    if (tail < n) {
        supported(s.presentations == 4, "metadata on nonimmersive stream");
        evolution(p, tail, n - tail, s, out.channels[3], motion);
    }
    if (s.presentations == 4)
        require(out.channels[3] == s.elements,
                "Atmos element count disagrees with major sync");
    out.samples = 40 - trimmed;
    out.sample_rate = 48000;
    out.presentations = s.presentations;
    out.element_channels = s.presentations == 4 ? out.channels[3] : 0;
    out.first_sample = s.samples;
    motion_frame(s, motion, out.samples);
    out.positions_valid = s.positions_valid;
    std::copy(s.positions.begin(), s.positions.end(), out.positions);
    s.samples += out.samples;
    s.ended = s.substreams[0].terminated;
}
} // namespace sthd
struct STHDDecoder {
    sthd::State state;
    bool strict_pcm_checksum = false;
    STHDFrameMotion motion{};
    char error[256]{};
};
extern "C" {
STHDDecoder *sthd_decoder_create(void) {
    try {
        return new STHDDecoder;
    } catch (...) {
        return nullptr;
    }
}
void sthd_decoder_destroy(STHDDecoder *d) { delete d; }
void sthd_decoder_reset(STHDDecoder *d) {
    if (d) {
        d->state = sthd::State{};
        d->motion = STHDFrameMotion{};
        d->error[0] = 0;
    }
}
uint32_t sthd_decoder_end_of_stream(const STHDDecoder *d) { return d && d->state.ended; }
const char *sthd_decoder_error(const STHDDecoder *d) { return d ? d->error : "null decoder"; }
uint32_t sthd_decoder_drc_valid(const STHDDecoder *d) {
    uint32_t mask = 0;
    if (d)
        for (unsigned i = 0; i < d->state.presentations; ++i)
            if (d->state.substreams[i].drc_valid)
                mask |= 1U << i;
    return mask;
}
STHDStatus sthd_decoder_motion(const STHDDecoder *d, STHDFrameMotion *motion) {
    if (!d || !motion)
        return STHD_INVALID_ARGUMENT;
    if (!d->motion.samples)
        return STHD_NEED_RESTART;
    *motion = d->motion;
    return STHD_OK;
}
STHDStatus sthd_decoder_set_strict_pcm_checksum(STHDDecoder *d, int strict) {
    if (!d || (strict != 0 && strict != 1))
        return STHD_INVALID_ARGUMENT;
    d->strict_pcm_checksum = strict != 0;
    return STHD_OK;
}
STHDStatus sthd_decoder_pcm_checksum(const STHDDecoder *d, STHDPCMChecksum *checksum) {
    if (!d || !checksum)
        return STHD_INVALID_ARGUMENT;
    *checksum = d->state.checksum;
    return STHD_OK;
}
const char *sthd_status_string(STHDStatus s) {
    static const char *names[] = {"ok",
                                  "invalid argument",
                                  "corrupt stream",
                                  "unsupported stream profile",
                                  "restart required",
                                  "buffer too small",
                                  "device unavailable",
                                  "unknown speaker layout",
                                  "out of memory",
                                  "unsupported audio output",
                                  "native audio failure",
                                  "audio timeout",
                                  "cancelled"};
    return unsigned(s) < sizeof(names) / sizeof(names[0]) ? names[unsigned(s)] : "unknown status";
}
STHDStatus sthd_decode_access_unit(STHDDecoder *d, const uint8_t *p, size_t n, STHDFrame *f) {
    if (!d || !p || !f)
        return STHD_INVALID_ARGUMENT;
    try {
        auto next = d->state;
        STHDFrame out{};
        STHDFrameMotion motion{};
        sthd::decode(next, p, n, out, motion, d->strict_pcm_checksum);
        d->state = next;
        d->motion = motion;
        *f = out;
        d->error[0] = 0;
        return STHD_OK;
    } catch (const sthd::Failure &e) {
        std::snprintf(d->error, sizeof(d->error), "%s", e.what());
        return e.status;
    } catch (const std::bad_alloc &) {
        return STHD_OUT_OF_MEMORY;
    } catch (...) {
        return STHD_CORRUPT_STREAM;
    }
}
}
