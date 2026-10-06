// SPDX-License-Identifier: LGPL-2.1-or-later
#include "TrueHDDecoder.h"
#include "../Sources/DecoderFramework/BitReader.hpp"
#include <array>
#include <cstdint>
#include <fstream>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <vector>

namespace {
void check(bool value, const char *message) {
    if (!value) throw std::runtime_error(message);
}
struct Writer {
    std::vector<uint8_t> bytes;
    size_t bits = 0;
    void put(uint32_t value, unsigned width) {
        for (unsigned n = width; n; --n, ++bits) {
            if (bits / 8 == bytes.size()) bytes.push_back(0);
            bytes[bits / 8] |= uint8_t(((value >> (n - 1)) & 1) << (7 - bits % 8));
        }
    }
    void signed_put(int32_t value, unsigned width) { put(uint32_t(value), width); }
    void align() { while (bits % 16) put(0, 1); }
};
constexpr unsigned low[4] = {0, 2, 6, 8}, high[4] = {1, 5, 7, 15};
constexpr int progression[40] = {
    0,7,14,22,29,37,44,52,59,67,74,82,89,97,104,112,119,127,134,142,
    149,157,164,172,179,187,194,202,209,217,224,232,239,247,254,262,269,277,284,292};
int32_t golden(unsigned frame, unsigned sample, unsigned channel) {
    if (channel < 8) return int32_t((channel + 1) * 100);
    if (channel == 8) return frame == 2 ? 300 : (frame == 1 ? 600 : 300) + progression[sample];
    if (channel == 9) return 400;
    if (channel == 10) return 256 + int32_t(sample % 4);
    if (channel == 11) return 7;
    if (channel == 12) return -8;
    return int32_t(channel * 100);
}
int32_t residual(unsigned channel) {
    if (channel < 8) return int32_t((channel + 1) * 100);
    if (channel == 8) return 300;
    if (channel == 9) return 400;
    if (channel == 10) return 512;
    if (channel == 11) return 0;
    if (channel == 12) return 4;
    return int32_t(channel * 100);
}
uint8_t fold(uint32_t value) { value ^= value >> 16; value ^= value >> 8; return uint8_t(value); }
void prediction(Writer &w, bool iir) {
    w.put(1, 1); w.put(1, 4); w.put(8, 4); w.put(10, 5); w.put(0, 3);
    w.signed_put(iir ? -256 : 256, 10);
    w.put(iir, 1);
    if (iir) { w.put(5, 4); w.put(0, 4); w.signed_put(12, 5); }
}
std::vector<uint8_t> substream(unsigned layer, unsigned frame, uint32_t checksum, unsigned suffix) {
    Writer w;
    const bool restart = frame == 0 || frame == 4;
    w.put(1, 1); w.put(restart, 1);
    if (restart) {
        const size_t start = w.bits;
        w.put(layer == 0 ? 0x31ea : layer == 3 ? 0x31ec : 0x31eb, 14);
        w.put(frame * 40, 16); w.put(low[layer], 4); w.put(high[layer], 4); w.put(high[layer], 4);
        w.put(0, 4); w.put(0, 23); w.put(0, 4);
        w.put(layer == 3 ? 31 : 24, 5); w.put(24, 5); w.put(24, 5);
        w.put(0, 1); w.put(fold(checksum), 8); w.put(0, 1); w.put(0, 15);
        for (unsigned c = 0; c <= high[layer]; ++c) w.put(c, 6);
        w.put(sthd::restart_checksum(w.bytes.data(), w.bits - start), 8);
    }
    // Disable only the optional offset guard between restarts.
    const bool guard_change = !restart && frame == 1;
    w.put(guard_change, 1);
    if (guard_change) w.put(253, 8);
    w.put(restart, 1); if (restart) w.put(40, 9);
    const bool matrix_update = restart || layer == 3;
    w.put(matrix_update, 1);
    if (matrix_update && layer == 0) {
        w.put(2, 4);
        w.put(0, 4); w.put(0, 4); w.put(0, 1);
        for (unsigned c = 0; c < 4; ++c) {
            const bool present = c == 0 || c == 2;
            w.put(present, 1); if (present) w.signed_put(1, 2);
        }
        w.put(1, 4); w.put(1, 4); w.put(0, 1);
        for (unsigned c = 0; c < 4; ++c) {
            const bool present = c == 1 || c == 3;
            w.put(present, 1); if (present) w.signed_put(c == 1 ? 2 : -1, 3);
        }
    } else if (matrix_update && layer < 3) {
        w.put(0, 4);
    } else if (matrix_update) {
        const bool configuration = restart || frame == 2 || frame == 3;
        w.put(configuration, 1);
        if (configuration) {
            const unsigned rows = frame == 2 ? 3 : 4;
            const bool refined = frame == 2 || frame == 3;
            w.put(1, 1); w.put(rows - 1, 4);
            const unsigned destination[4] = {9, 10, 11, 8};
            const unsigned fraction[4] = {14, 4, 14, refined ? 2U : 1U};
            const unsigned shift[4] = {1, 0, 1, refined ? 1U : 2U};
            for (unsigned m = 0; m < rows; ++m) {
                w.put(destination[m], 4); w.put(fraction[m], 4); w.put(shift[m], 3);
                w.put(m == 1 ? 2 : 0, 2); w.put(m == 2 ? 5 : 0, 4);
                w.put(m == 2 ? 0 : 1U << destination[m], 16);
            }
            w.signed_put(16384, 16); w.signed_put(16, 6);
            if (rows == 4) w.signed_put(refined ? 4 : 1, refined ? 4 : 3);
        }
        const bool interpolation = frame != 2;
        w.put(interpolation, 1);
        if (interpolation) {
            w.put(restart, 1);
            if (restart) {
                w.put(1, 1);
                for (unsigned m = 0; m < 4; ++m) { w.put(m == 3 ? 1 : 0, 4); w.put(0, 2); }
                w.signed_put(1, 2);
            }
            // Frame 3 reactivates an inherited delta after a smaller configuration.
        }
    }
    w.put(restart, 1);
    if (restart) for (unsigned c = 0; c <= high[layer]; ++c) w.signed_put(0, 4);
    w.put(restart, 1);
    if (restart)
        for (unsigned c = 0; c <= high[layer]; ++c) w.put(c == 10 || c == 12 ? 2 : 0, 4);
    for (unsigned c = low[layer]; c <= high[layer]; ++c) {
        w.put(1, 1);
        if (restart && c == 12) { prediction(w, false); prediction(w, true); }
        else { w.put(restart, 1); if (restart) w.put(0, 4); w.put(restart, 1); if (restart) w.put(0, 4); }
        if (restart) w.put(0, 1);
        w.put(0, 2); w.put(16, 5);
    }
    for (unsigned n = 0; n < 40; ++n) {
        if (layer == 3) w.put(n % 4, 2);
        for (unsigned c = low[layer]; c <= high[layer]; ++c) {
            unsigned quant = c == 10 || c == 12 ? 2 : 0;
            unsigned width = 16 - quant;
            w.put(uint32_t(residual(c) / int32_t(1U << quant)) + (1U << (width - 1)), width);
        }
    }
    w.put(1, 1); w.align();
    if (frame == 4) { w.put(0xd234,16); w.put(suffix,16); }
    uint8_t parity = 0; for (auto b : w.bytes) parity ^= b;
    auto crc = sthd::checksum8(w.bytes.data(), w.bytes.size());
    w.bytes.push_back(parity ^ 0xa9); w.bytes.push_back(crc);
    return w.bytes;
}
}
void sthd_matrix_syntax_tests(const char *fixture) {
    std::ifstream input(fixture, std::ios::binary);
    std::array<uint8_t,36> header{};
    check(bool(input.read(reinterpret_cast<char*>(header.data()), header.size())), "matrix test major sync template");
    std::vector<uint8_t> sync(header.begin() + 4, header.end());
    for (unsigned suffix : {0xe000U, 0xd234U}) {
    std::unique_ptr<STHDDecoder,decltype(&sthd_decoder_destroy)> decoder(sthd_decoder_create(),sthd_decoder_destroy);
    check(bool(decoder), "matrix test decoder");
    check(sthd_decoder_set_strict_pcm_checksum(decoder.get(),1)==STHD_OK, "matrix strict mode");
    std::array<uint32_t,4> checks{};
    for (unsigned frame = 0; frame < 5; ++frame) {
        const bool restart = frame == 0 || frame == 4;
        std::vector<uint8_t> au(4,0);
        if (restart) au.insert(au.end(),sync.begin(),sync.end());
        const size_t directory=au.size(); au.resize(au.size()+8);
        unsigned end=0;
        for (unsigned layer=0;layer<4;++layer) {
            auto payload=substream(layer,frame,checks[layer],suffix);
            if (restart) checks[layer]=0;
            end+=unsigned(payload.size());
            unsigned word=(restart?0:0x4000)|0x2000|(layer==0?0x1000:0)|(end/2);
            au[directory+layer*2]=uint8_t(word>>8);au[directory+layer*2+1]=uint8_t(word);
            au.insert(au.end(),payload.begin(),payload.end());
        }
        au[2]=uint8_t((frame*40)>>8);au[3]=uint8_t(frame*40);
        unsigned length=unsigned(au.size()/2), parity=length^(frame*40);
        for(unsigned i=0;i<8;++i)parity^=au[directory+i];
        parity^=parity>>8;parity^=parity>>4;
        unsigned word=((parity^15)&15)<<12|length;au[0]=uint8_t(word>>8);au[1]=uint8_t(word);
        STHDFrame decoded{};
        auto status=sthd_decode_access_unit(decoder.get(),au.data(),au.size(),&decoded);
        if(status!=STHD_OK)throw std::runtime_error(sthd_decoder_error(decoder.get()));
        for(unsigned layer=0;layer<4;++layer)
            for(unsigned n=0;n<40;++n)
                for(unsigned c=0;c<=high[layer];++c) {
                    const int32_t expected=layer==3?golden(frame,n,c):int32_t((c+1)*100);
                    const unsigned wave[8]={0,1,2,3,6,7,4,5};
                    unsigned output=layer==2?wave[c]:c;
                    check(decoded.pcm[layer][n*(high[layer]+1)+output]==expected,"matrix syntax golden PCM");
                    checks[layer]^=(uint32_t(expected)&0xffffffU)<<(c&7);
                }
        if(frame==4) {
            STHDPCMChecksum checksum{};check(sthd_decoder_pcm_checksum(decoder.get(),&checksum)==STHD_OK,"matrix checks query");
            check(checksum.checked_layers==15 && !checksum.mismatched_layers,"matrix golden restart checksum");
            check(decoded.samples==40 && sthd_decoder_end_of_stream(decoder.get())==1,
                  "zero-trim terminator preserves all 40 samples");
            auto saved=decoded;
            check(sthd_decode_access_unit(decoder.get(),au.data(),au.size(),&decoded)==STHD_CORRUPT_STREAM &&
                  !std::memcmp(&saved,&decoded,sizeof(decoded)), "data after zero-trim EOS rejected transactionally");
            check(sthd_decoder_end_of_stream(decoder.get())==1,"failed AU preserves EOS");
            sthd_decoder_reset(decoder.get());
            check(sthd_decoder_end_of_stream(decoder.get())==0 && sthd_decoder_end_of_stream(nullptr)==0,
                  "reset clears EOS");
        }
    }
    }
}
