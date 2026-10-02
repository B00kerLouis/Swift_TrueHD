// SPDX-License-Identifier: AGPL-3.0-only
#include "BitReader.hpp"
#include <algorithm>
#include <array>
#include <cstdio>
#include <cstring>
#include <memory>
#include <new>
#include <string>
#include <vector>
namespace sthd {
struct Channel {
    int offset = 0, book = 0, lsbs = 24, order = 0, shift = 0;
    std::array<int32_t, 8> coefficients{}, history{};
};
struct Matrix {
    unsigned output = 0, frac = 14, mask = 0;
    std::array<int32_t, 16> coefficients{};
};
struct Substream {
    bool initialized = false;
    unsigned minimum = 0, maximum = 0, matrix_max = 0, type = 0, block = 8;
    unsigned matrix_count = 0;
    std::array<Channel, 16> channel{};
    std::array<int, 16> shifts{}, assignments{};
    std::array<Matrix, 16> matrices{};
    uint32_t lossless = 0;
    int drc = 0;
};
struct State {
    unsigned presentations = 0;
    uint64_t samples = 0;
    bool positions_valid = false;
    std::array<STHDPosition, 16> positions{};
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
static int32_t pcm24(int64_t value) {
    const uint32_t u = uint32_t(uint64_t(value)) & 0xffffff;
    return u < 0x800000 ? int32_t(u) : int32_t(int64_t(u) - 0x1000000);
}
static void restart(Bits &b, Substream &s, unsigned layer, unsigned presentations) {
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
    b.zero(4);
    b.skip(23); // no matrix noise; generator seed has no effect
    b.skip(4);
    b.skip(5);
    b.skip(5);
    b.skip(5);
    b.zero(1);
    const uint8_t lossless = uint8_t(b.read(8));
    if (s.initialized)
        require(fold32(s.lossless) == lossless, "restart lossless PCM checksum mismatch");
    else
        require(lossless == 0, "first restart has nonzero preceding PCM checksum");
    b.skip(1);
    b.zero(15); // high-resolution timing carried by the encoder
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
    s = Substream{};
    s.drc = drc;
    s.initialized = true;
    s.type = type;
    s.minimum = minimum;
    s.maximum = maximum;
    s.matrix_max = matrix_max;
    s.assignments = assignments;
    (void)presentations;
}
static void filter(Bits &b, Channel &c) {
    if (!b.read(1))
        return;
    c.order = int(b.read(4));
    supported(c.order <= 8, "unsupported FIR order");
    if (!c.order)
        return;
    c.shift = int(b.read(4));
    const unsigned bits = b.read(5), shift = b.read(3);
    require(bits >= 1 && bits <= 16 && bits + shift <= 16, "invalid FIR coefficient precision");
    for (int i = 0; i < c.order; ++i)
        c.coefficients[size_t(i)] = b.signed_read(bits) * int32_t(1U << shift);
    supported(b.read(1) == 0, "FIR explicit state unsupported");
}
static void matrices(Bits &b, Substream &s) {
    if (s.type != 0x31ec) {
        s.matrix_count = b.read(4);
        supported(s.matrix_count <= 15, "too many primitive matrices");
        for (unsigned i = 0; i < s.matrix_count; ++i) {
            auto &m = s.matrices[i];
            m = Matrix{};
            m.output = b.read(4);
            m.frac = b.read(4);
            require(m.output <= s.matrix_max, "matrix destination out of range");
            supported(b.read(1) == 0, "bypassed matrix LSBs unsupported");
            for (unsigned c = 0; c <= s.matrix_max; ++c)
                if (b.read(1)) {
                    m.mask |= 1U << c;
                    m.coefficients[c] = b.signed_read(m.frac + 2);
                }
            supported(b.read(4) == 0, "matrix dither unsupported");
        }
    } else {
        supported(b.read(1) == 1, "unsupported extended matrix syntax");
        if (b.read(1)) {
            s.matrix_count = b.read(4) + 1;
            for (unsigned i = 0; i < s.matrix_count; ++i) {
                auto &m = s.matrices[i];
                m = Matrix{};
                m.output = b.read(4);
                m.frac = b.read(4);
                require(m.output <= s.matrix_max, "extended matrix destination out of range");
                supported(b.read(3) == 1 && b.read(2) == 0 && b.read(4) == 0,
                          "unsupported extended matrix shift/LSB/dither");
                m.mask = b.read(s.matrix_max + 1);
            }
        }
        require(s.matrix_count > 0, "extended matrix update without configuration");
        for (unsigned i = 0; i < s.matrix_count; ++i) {
            auto &m = s.matrices[i];
            for (unsigned c = 0; c <= s.matrix_max; ++c)
                if (m.mask & (1U << c))
                    m.coefficients[c] = b.signed_read(m.frac + 2);
        }
        supported(b.read(1) == 0, "extended coefficient interpolation unsupported");
    }
}
static void parameters(Bits &b, Substream &s) {
    supported(b.read(1) == 0, "nondefault parameter-presence guards unsupported");
    if (b.read(1))
        s.block = b.read(9);
    require(s.block >= 8 && s.block <= 40, "invalid audio block size");
    if (b.read(1))
        matrices(b, s);
    if (b.read(1))
        for (unsigned c = 0; c <= s.matrix_max; ++c) {
            s.shifts[c] = b.signed_read(4);
            supported(s.shifts[c] >= 0, "negative PCM output shift unsupported");
        }
    supported(b.read(1) == 0, "quantization steps unsupported by this encoder profile");
    for (unsigned c = s.minimum; c <= s.maximum; ++c)
        if (b.read(1)) {
            auto &p = s.channel[c];
            filter(b, p);
            supported(b.read(1) == 0, "IIR unsupported by this encoder profile");
            if (b.read(1))
                p.offset = b.signed_read(15);
            p.book = int(b.read(2));
            p.lsbs = int(b.read(5));
            require(p.lsbs <= 24, "invalid Huffman LSB width");
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
    const int sign = p.lsbs + (p.book ? 2 - p.book : -1);
    int64_t offset = p.offset;
    if (p.book)
        offset -= int64_t(7) << p.lsbs;
    if (sign >= 0)
        offset -= int64_t(1) << sign;
    return wrap32(offset + (int64_t(index) << p.lsbs) + b.read(unsigned(p.lsbs)));
}
static unsigned decode_substream(const uint8_t *p, size_t bytes, Substream &s, unsigned layer,
                                 unsigned presentations,
                                 std::array<std::array<int32_t, 16>, 40> &raw, STHDFrame &out) {
    require(bytes >= 4, "short audio substream");
    uint8_t parity = 0;
    for (size_t i = 0; i < bytes - 1; ++i)
        parity ^= p[i];
    require(parity == 0xa9, "audio substream parity mismatch");
    require(checksum8(p, bytes - 2) == p[bytes - 1], "audio substream CRC mismatch");
    Bits b(p, bytes - 2);
    unsigned at = 0;
    for (unsigned blocks = 0; blocks < 5; ++blocks) {
        if (b.read(1)) {
            if (b.read(1))
                restart(b, s, layer, presentations);
            if (!s.initialized)
                throw Failure(STHD_NEED_RESTART, "audio parameters require a restart");
            parameters(b, s);
        }
        require(s.initialized && at + s.block <= 40, "audio blocks exceed access unit");
        for (unsigned f = at; f < at + s.block; ++f)
            for (unsigned c = s.minimum; c <= s.maximum; ++c) {
                auto &ch = s.channel[c];
                int64_t prediction = 0;
                for (int i = 0; i < ch.order; ++i)
                    prediction += int64_t(ch.coefficients[size_t(i)]) * ch.history[size_t(i)];
                const int32_t value =
                    wrap32(int64_t(residual(b, ch)) + floor_shift(prediction, unsigned(ch.shift)));
                for (unsigned i = 7; i > 0; --i)
                    ch.history[i] = ch.history[i - 1];
                ch.history[0] = value;
                raw[f][c] = value;
            }
        // Every presentation starts from the unmodified shared transport basis.
        // Primitive rows are sequential and may depend on preceding rows.
        for (unsigned f = at; f < at + s.block; ++f) {
            auto v = raw[f];
            for (unsigned i = 0; i < s.matrix_count; ++i) {
                const auto &m = s.matrices[i];
                int64_t sum = 0;
                for (unsigned c = 0; c <= s.matrix_max; ++c)
                    sum += int64_t(v[c]) * m.coefficients[c];
                v[m.output] = wrap32(floor_shift(sum, m.frac));
            }
            for (unsigned c = 0; c <= s.matrix_max; ++c) {
                int32_t value = pcm24(int64_t(v[c]) * (int64_t(1) << s.shifts[c]));
                out.pcm[layer][f * (s.matrix_max + 1) + unsigned(s.assignments[c])] = value;
            }
        }
        at += s.block;
        if (b.read(1))
            break;
    }
    require(at == 40, "access unit does not contain 40 PCM samples");
    b.align(16);
    unsigned trim = 0;
    if (b.pos < b.limit) {
        require(b.limit - b.pos == 32 && b.read(16) == 0xd234, "invalid end-of-stream marker");
        unsigned word = b.read(16);
        require((word & 0xe000) == 0xe000, "invalid PCM trim marker");
        trim = word & 0x1fff;
        require(trim > 0 && trim < 40, "invalid final PCM trim count");
    }
    require(b.pos == b.limit, "unexpected audio payload tail");
    out.channels[layer] = s.matrix_max + 1;
    // Lossless check is evaluated in matrix-channel order before ch_assign.
    for (unsigned f = 0; f < 40 - trim; ++f)
        for (unsigned c = 0; c <= s.matrix_max; ++c)
            s.lossless ^=
                (uint32_t(out.pcm[layer][f * (s.matrix_max + 1) + unsigned(s.assignments[c])]) &
                 0xffffffU)
                << (c & 7);
    return trim;
}
static void oamd(Bits &b, State &s, unsigned channels) {
    supported(b.read(2) == 0, "unsupported OAMD version");
    require(b.read(5) + 1 == channels, "OAMD element count mismatch");
    supported(b.read(1) == 1 && b.read(1) == 1 && b.read(1) == 0, "unsupported OAMD bed structure");
    supported(b.read(4) == 1 && b.read(4) == 1, "unsupported OAMD element list");
    const unsigned bytes = b.variable(4) + 1;
    const size_t end = b.pos + size_t(bytes) * 8;
    require(end <= b.limit, "OAMD object element exceeds payload");
    supported(b.read(1) == 0, "discarded object element unsupported");
    unsigned mode = b.read(2);
    if (mode == 1)
        b.skip(2);
    else if (mode == 2)
        b.skip(5);
    else
        supported(mode == 0, "unsupported OAMD sample offset");
    supported(b.read(3) == 0, "multiple OAMD object blocks unsupported");
    b.skip(6);
    unsigned ramp = b.read(2);
    if (ramp == 3) {
        supported(b.read(1) == 0, "unsupported ramp duration encoding");
        b.skip(11);
    }
    supported(b.read(1) == 1, "reserved OAMD object data unsupported");
    std::array<STHDPosition, 16> positions{};
    positions[0] = {0, 1, -1};
    for (unsigned c = 0; c < channels; ++c) {
        supported(b.read(1) == 0, "inactive OAMD element unsupported");
        supported(b.read(2) == (c == 0 ? 0U : 3U), "nondefault OAMD gain unsupported");
        supported(b.read(1) == 1, "nondefault OAMD priority unsupported");
        if (c) {
            const unsigned x = b.read(6), y = b.read(6), sign = b.read(1), z = b.read(4);
            require(x <= 62 && y <= 62, "OAMD coordinate out of range");
            positions[c] = {float(x) / 31.0f - 1.0f, 1.0f - float(y) / 31.0f,
                            (sign ? 1.0f : -1.0f) * float(z) / 15.0f};
            supported(b.read(1) == 0 && b.read(3) == 0 && b.read(1) == 1 && b.read(2) == 0 &&
                          b.read(1) == 0 && b.read(1) == 0,
                      "unsupported OAMD distance/zone/size/screen/snap");
        }
        supported(b.read(1) == 0, "additional OAMD table data unsupported");
    }
    // This project's spatial coder uses fixed anchors. Reject moving metadata
    // rather than rendering future coordinates too early or ignoring ramps.
    if (s.positions_valid)
        for (unsigned c = 0; c < channels; ++c)
            supported(s.positions[c].x == positions[c].x && s.positions[c].y == positions[c].y &&
                          s.positions[c].z == positions[c].z,
                      "moving OAMD positions outside fixed-basis encoder profile");
    s.positions = positions;
    s.positions_valid = true;
    while (b.pos < end)
        b.zero(1);
    require(b.pos == end, "OAMD object length mismatch");
    while (b.pos < b.limit)
        b.zero(1);
}
static void evolution(const uint8_t *au, size_t prefix, size_t bytes, State &s, unsigned channels) {
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
    oamd(ob, s, channels);
    require(e.read(5) == 0, "missing EMDF payload terminator");
    supported(e.read(2) == 1 && e.read(2) == 0, "unsupported EMDF protection lengths");
    const size_t protection = e.pos;
    const uint8_t expected = uint8_t(e.read(8));
    authenticate_evolution(au, prefix, p + 4, en, protection, expected);
    while (e.pos < e.limit)
        e.zero(1);
}
static void decode(State &s, const uint8_t *p, size_t n, STHDFrame &out) {
    require(n >= 4 && n <= STHD_MAX_ACCESS_UNIT && !(n & 1), "invalid access unit size");
    require(size_t(be16(p) & 0xfff) * 2 == n, "access unit length mismatch");
    size_t directory = 4;
    bool major = n >= 8 && p[4] == 0xf8 && p[5] == 0x72 && p[6] == 0x6f;
    if (major) {
        supported(p[7] == 0xba, "MLP/non-FBA stream unsupported");
        require(n >= 32, "truncated major sync");
        supported((p[8] >> 4) == 0, "only project 48 kHz profile supported");
        const unsigned presentations = p[20] >> 4;
        supported(presentations == 3 || presentations == 4,
                  "unsupported major-sync substream count");
        const size_t sync_bytes = presentations == 4 ? 32 : 28;
        require(n >= 4 + sync_bytes, "truncated extended major sync");
        require(checksum16(p + 4, sync_bytes - 2) ==
                    uint16_t(p[4 + sync_bytes - 2] | (unsigned(p[4 + sync_bytes - 1]) << 8)),
                "major sync CRC mismatch");
        if (s.presentations)
            supported(s.presentations == presentations, "presentation topology changed midstream");
        s.presentations = presentations;
        directory += sync_bytes;
    }
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
            supported((drc & 0x7f) == 0x70, "unsupported DRC interpolation word");
            s.substreams[i].drc = int((drc >> 7) & 0x1ff);
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
        unsigned trim = decode_substream(p + at + begin, ends[i] - begin, s.substreams[i], i,
                                         s.presentations, raw, out);
        if (i)
            require(trim == trimmed, "presentation PCM trim counts disagree");
        trimmed = trim;
        out.drc_gain_code[i] = s.substreams[i].drc;
    }
    const size_t tail = at + ends[s.presentations - 1];
    if (tail < n) {
        supported(s.presentations == 4, "metadata on nonimmersive stream");
        evolution(p, tail, n - tail, s, out.channels[3]);
    }
    if (s.presentations == 4)
        require(s.positions_valid, "Atmos elements lack OAMD positions");
    out.samples = 40 - trimmed;
    out.sample_rate = 48000;
    out.presentations = s.presentations;
    out.element_channels = s.presentations == 4 ? out.channels[3] : 0;
    out.first_sample = s.samples;
    out.positions_valid = s.positions_valid;
    std::copy(s.positions.begin(), s.positions.end(), out.positions);
    s.samples += out.samples;
}
} // namespace sthd
struct STHDDecoder {
    sthd::State state;
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
        d->error[0] = 0;
    }
}
const char *sthd_decoder_error(const STHDDecoder *d) { return d ? d->error : "null decoder"; }
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
        sthd::decode(next, p, n, out);
        d->state = next;
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
