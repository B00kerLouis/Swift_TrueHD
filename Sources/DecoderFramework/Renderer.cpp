// SPDX-License-Identifier: LGPL-2.1-or-later
#include "include/TrueHDDecoder.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <vector>
namespace {
constexpr double half_pi = 1.57079632679489661923;
struct SpeakerPosition {
    double x, y, z;
};
SpeakerPosition position(STHDSpeaker s, bool five) {
    switch (s) {
    case STHD_FL:
        return {-1, 1, 0};
    case STHD_FR:
        return {1, 1, 0};
    case STHD_FC:
        return {0, 1, 0};
    case STHD_BL:
        return {-1, five ? 0.0 : -1.0, 0};
    case STHD_BR:
        return {1, five ? 0.0 : -1.0, 0};
    case STHD_SL:
        return {-1, 0, 0};
    case STHD_SR:
        return {1, 0, 0};
    case STHD_TFL:
        return {-1, 1, 1};
    case STHD_TFR:
        return {1, 1, 1};
    case STHD_TML:
        return {-1, 0, 1};
    case STHD_TMR:
        return {1, 0, 1};
    case STHD_TBL:
        return {-1, -1, 1};
    case STHD_TBR:
        return {1, -1, 1};
    case STHD_FWL:
        return {-1, .5, 0};
    case STHD_FWR:
        return {1, .5, 0};
    default:
        return {0, 0, 0};
    }
}
bool valid(const STHDLayout &l) {
    if (l.channels < 2 || l.channels > 16)
        return false;
    unsigned seen = 0;
    for (unsigned i = 0; i < l.channels; ++i) {
        unsigned s = unsigned(l.speakers[i]);
        if (s > unsigned(STHD_FWR) || (seen & (1U << s)))
            return false;
        seen |= 1U << s;
    }
    STHDLayout candidate{};
    const char *names[] = {"2.0",   "5.1",   "7.1",   "5.1.2",     "5.1.4",       "7.1.2",
                           "7.1.4", "7.1.6", "9.1.6", "5.1(back)", "5.1.2(back)", "5.1.4(back)"};
    for (auto name : names) {
        sthd_layout_named(name, &candidate);
        unsigned mask = 0;
        for (unsigned i = 0; i < candidate.channels; ++i)
            mask |= 1U << unsigned(candidate.speakers[i]);
        if (mask == seen)
            return true;
    }
    return false;
}
// Room-coordinate panning: interpolate power between adjacent front/side/rear
// planes, then between left/centre/right speakers. Existing anchors route to
// their matching speakers exactly. Fewer height rows fold continuously to the
// available rows; height PCM is never discarded or copied into arbitrary slots.
void plane_gains(const STHDLayout &l, STHDPosition p, bool top, double weight,
                 std::array<double, 16> &g) {
    unsigned floor_channels = 0;
    for (unsigned i = 0; i < l.channels; ++i)
        if (l.speakers[i] <= STHD_SR)
            ++floor_channels;
    const bool five = floor_channels == 6;
    std::vector<double> rows;
    for (unsigned i = 0; i < l.channels; ++i)
        if (l.speakers[i] != STHD_LFE) {
            auto s = position(l.speakers[i], five);
            if ((s.z > 0) == top && std::find(rows.begin(), rows.end(), s.y) == rows.end())
                rows.push_back(s.y);
        }
    if (rows.empty())
        return;
    std::sort(rows.begin(), rows.end());
    double y = std::clamp(double(p.y), rows.front(), rows.back());
    size_t a = 0, b = 0;
    while (a + 1 < rows.size() && y > rows[a + 1])
        ++a;
    if (a + 1 < rows.size())
        b = a + 1;
    else
        b = a;
    double t = a == b ? 0 : (y - rows[a]) / (rows[b] - rows[a]);
    for (unsigned which = 0; which < (a == b ? 1U : 2U); ++which) {
        size_t row = which ? b : a;
        double w = weight * (a == b ? 1 : (which ? std::sin(t * half_pi) : std::cos(t * half_pi)));
        std::vector<unsigned> indices;
        for (unsigned i = 0; i < l.channels; ++i)
            if (l.speakers[i] != STHD_LFE) {
                auto s = position(l.speakers[i], five);
                if ((s.z > 0) == top && s.y == rows[row])
                    indices.push_back(i);
            }
        std::sort(indices.begin(), indices.end(), [&](unsigned x, unsigned z) {
            return position(l.speakers[x], five).x < position(l.speakers[z], five).x;
        });
        double x = std::clamp(double(p.x), position(l.speakers[indices.front()], five).x,
                              position(l.speakers[indices.back()], five).x);
        size_t left = 0;
        while (left + 1 < indices.size() && x > position(l.speakers[indices[left + 1]], five).x)
            ++left;
        size_t right = std::min(left + 1, indices.size() - 1);
        double lx = position(l.speakers[indices[left]], five).x,
               rx = position(l.speakers[indices[right]], five).x;
        double fraction = left == right ? 0 : (x - lx) / (rx - lx);
        g[indices[left]] += w * (left == right ? 1 : std::cos(fraction * half_pi));
        if (right != left)
            g[indices[right]] += w * std::sin(fraction * half_pi);
    }
}
} // namespace
extern "C" {
const char *sthd_speaker_name(STHDSpeaker s) {
    static const char *names[] = {"FL",  "FR",  "FC",  "LFE", "BL",  "BR",  "SL",  "SR",
                                  "TFL", "TFR", "TBL", "TBR", "TML", "TMR", "FWL", "FWR"};
    return unsigned(s) < 16 ? names[unsigned(s)] : "unknown";
}
STHDStatus sthd_layout_named(const char *name, STHDLayout *l) {
    if (!name || !l)
        return STHD_INVALID_ARGUMENT;
    // WAVE/WASAPI commonly labels a five-channel surround pair BL/BR,
    // whereas other APIs use SL/SR. Both physical orders are supported.
    const size_t length = std::strlen(name);
    const bool back = length >= 6 && std::strcmp(name + length - 6, "(back)") == 0;
    char base[16]{};
    if (back) {
        if (length - 6 >= sizeof(base) || std::strncmp(name, "5.1", 3) != 0)
            return STHD_UNKNOWN_LAYOUT;
        std::memcpy(base, name, length - 6);
        name = base;
    }
    const bool stereo = std::strcmp(name, "2.0") == 0;
    const bool five = std::strncmp(name, "5.1", 3) == 0;
    const bool seven = std::strncmp(name, "7.1", 3) == 0;
    const bool nine = std::strcmp(name, "9.1.6") == 0;
    unsigned height = 0;
    if (stereo) {
    } else if (std::strcmp(name, "5.1") == 0 || std::strcmp(name, "7.1") == 0) {
    } else if (std::strcmp(name, "5.1.2") == 0 || std::strcmp(name, "7.1.2") == 0)
        height = 2;
    else if (std::strcmp(name, "5.1.4") == 0 || std::strcmp(name, "7.1.4") == 0)
        height = 4;
    else if (std::strcmp(name, "7.1.6") == 0 || nine)
        height = 6;
    else
        return STHD_UNKNOWN_LAYOUT;
    if (!stereo && !five && !seven && !nine)
        return STHD_UNKNOWN_LAYOUT;
    STHDLayout out{};
    auto add = [&](STHDSpeaker s) { out.speakers[out.channels++] = s; };
    add(STHD_FL);
    add(STHD_FR);
    if (!stereo) {
        add(STHD_FC);
        add(STHD_LFE);
        if (!five) {
            add(STHD_BL);
            add(STHD_BR);
        }
        if (five && back) {
            add(STHD_BL);
            add(STHD_BR);
        } else {
            add(STHD_SL);
            add(STHD_SR);
        }
        if (height >= 4) {
            add(STHD_TFL);
            add(STHD_TFR);
            add(STHD_TBL);
            add(STHD_TBR);
        }
        if (height == 2 || height == 6) {
            add(STHD_TML);
            add(STHD_TMR);
        }
        if (nine) {
            add(STHD_FWL);
            add(STHD_FWR);
        }
    }
    *l = out;
    return STHD_OK;
}
uint32_t sthd_wave_channel_mask(const STHDLayout *l) {
    if (!l || !valid(*l))
        return 0;
    static const uint32_t bits[16] = {1,    2,     4,     8,      16, 32, 512, 1024,
                                      4096, 16384, 32768, 131072, 0,  0,  0,   0};
    uint32_t mask = 0;
    int previous = -1;
    for (unsigned i = 0; i < l->channels; ++i) {
        auto s = unsigned(l->speakers[i]);
        if (!bits[s] || int(bits[s]) <= previous)
            return 0;
        previous = int(bits[s]);
        mask |= bits[s];
    }
    return mask;
}
STHDStatus sthd_render(const STHDFrame *f, const STHDLayout *l, float gain, float *out,
                       size_t capacity) try {
    if (!f || !l || !out || !valid(*l) || !std::isfinite(gain) || gain < 0 || f->samples > 40 ||
        f->samples == 0 || f->presentations < 3 || f->presentations > 4 || f->sample_rate != 48000)
        return STHD_INVALID_ARGUMENT;
    if (capacity < size_t(f->samples) * l->channels)
        return STHD_BUFFER_TOO_SMALL;
    if (f->channels[0] != 2 || f->channels[1] != 6 || f->channels[2] != 8)
        return STHD_INVALID_ARGUMENT;
    bool immersive = false;
    for (unsigned i = 0; i < l->channels; ++i)
        if (l->speakers[i] >= STHD_TFL)
            immersive = true;
    const double scale = double(gain) / 8388608.0;
    if (!immersive) {
        unsigned layer = l->channels == 2 ? 0 : (l->channels == 6 ? 1 : 2);
        if (f->presentations == 3 && layer < 2) {
            // For cumulative channel subsets, form the requested downmix from
            // the complete 7.1 presentation. Raw extraction preserves encoded PCM.
            constexpr double surround_gain = 0.7071067811865475244;
            for (unsigned n = 0; n < f->samples; ++n)
                for (unsigned c = 0; c < l->channels; ++c) {
                    const int32_t *v = f->pcm[2] + n * 8;
                    double value = 0;
                    auto speaker = l->speakers[c];
                    if (layer == 0) {
                        value = speaker == STHD_FL
                                    ? v[0] + surround_gain * (double(v[2]) + v[4] + v[6])
                                    : v[1] + surround_gain * (double(v[2]) + v[5] + v[7]);
                    } else if (speaker == STHD_SL || speaker == STHD_BL)
                        value = surround_gain * (double(v[4]) + v[6]);
                    else if (speaker == STHD_SR || speaker == STHD_BR)
                        value = surround_gain * (double(v[5]) + v[7]);
                    else
                        value = v[unsigned(speaker)];
                    out[n * l->channels + c] = float(value * scale);
                }
            return STHD_OK;
        }
        for (unsigned n = 0; n < f->samples; ++n)
            for (unsigned c = 0; c < l->channels; ++c) {
                unsigned source = unsigned(l->speakers[c]);
                if (layer == 1 && (source == STHD_SL || source == STHD_SR))
                    source -= 2;
                out[n * l->channels + c] =
                    float(f->pcm[layer][n * f->channels[layer] + source] * scale);
            }
        return STHD_OK;
    }
    unsigned ground_channels = 0;
    for (unsigned c = 0; c < l->channels; ++c)
        if (l->speakers[c] <= STHD_SR)
            ++ground_channels;
    if (f->presentations == 3 && ground_channels == 6) {
        // Adding silent height outputs must not change the 5.1 bed downmix
        // gain relative to a six-channel device playing the same plain bed.
        constexpr double surround_gain = 0.7071067811865475244;
        for (unsigned n = 0; n < f->samples; ++n)
            for (unsigned c = 0; c < l->channels; ++c) {
                const int32_t *v = f->pcm[2] + n * 8;
                auto speaker = l->speakers[c];
                double value = 0;
                if (speaker == STHD_SL || speaker == STHD_BL)
                    value = surround_gain * (double(v[4]) + v[6]);
                else if (speaker == STHD_SR || speaker == STHD_BR)
                    value = surround_gain * (double(v[5]) + v[7]);
                else if (speaker <= STHD_LFE)
                    value = v[unsigned(speaker)];
                out[n * l->channels + c] = float(value * scale);
            }
        return STHD_OK;
    }
    bool top = false;
    for (unsigned i = 0; i < l->channels; ++i)
        if (l->speakers[i] >= STHD_TFL && l->speakers[i] <= STHD_TMR)
            top = true;
    bool elements = f->presentations == 4;
    if (elements &&
        (!f->positions_valid ||
         (f->element_channels != 12 && f->element_channels != 14 && f->element_channels != 16) ||
         f->channels[3] != f->element_channels))
        return STHD_INVALID_ARGUMENT;
    const unsigned channels = elements ? f->element_channels : 8;
    std::array<std::array<double, 16>, 16> gains{};
    static constexpr STHDPosition core[8] = {{-1, 1, 0},  {1, 1, 0},  {0, 1, 0},  {0, 1, -1},
                                             {-1, -1, 0}, {1, -1, 0}, {-1, 0, 0}, {1, 0, 0}};
    for (unsigned c = 0; c < channels; ++c) {
        STHDPosition p = elements ? f->positions[c] : core[c];
        if (!std::isfinite(p.x) || !std::isfinite(p.y) || !std::isfinite(p.z) || p.x < -1 ||
            p.x > 1 || p.y < -1 || p.y > 1 || p.z < -1 || p.z > 1)
            return STHD_INVALID_ARGUMENT;
        if (c == (elements ? 0U : 3U)) {
            for (unsigned i = 0; i < l->channels; ++i)
                if (l->speakers[i] == STHD_LFE)
                    gains[c][i] = 1;
        } else {
            const double elevation = top ? std::clamp(double(p.z), 0.0, 1.0) : 0;
            plane_gains(*l, p, false, std::cos(elevation * half_pi), gains[c]);
            if (top)
                plane_gains(*l, p, true, std::sin(elevation * half_pi), gains[c]);
        }
    }
    for (unsigned n = 0; n < f->samples; ++n)
        for (unsigned speaker = 0; speaker < l->channels; ++speaker) {
            double sum = 0;
            for (unsigned c = 0; c < channels; ++c)
                sum += f->pcm[elements ? 3 : 2][n * channels + c] * gains[c][speaker];
            out[n * l->channels + speaker] = float(sum * scale);
        }
    return STHD_OK;
} catch (...) {
    return STHD_OUT_OF_MEMORY;
}
STHDStatus sthd_render_motion(const STHDFrame *f, const STHDFrameMotion *motion,
                              const STHDLayout *layout, float gain, float *out,
                              size_t capacity) try {
    if (!f || !motion || !layout || !out || !valid(*layout) || !std::isfinite(gain) || gain < 0 ||
        motion->samples != f->samples || motion->first_sample != f->first_sample ||
        f->samples < 1 || f->samples > 40 || f->sample_rate != 48000 ||
        f->presentations < 3 || f->presentations > 4 ||
        f->channels[0] != 2 || f->channels[1] != 6 || f->channels[2] != 8 ||
        (f->presentations == 4 &&
         ((f->element_channels != 12 && f->element_channels != 14 && f->element_channels != 16) ||
          f->channels[3] != f->element_channels)))
        return STHD_INVALID_ARGUMENT;
    if (f->presentations != 4)
        return sthd_render(f, layout, gain, out, capacity);
    bool spatial_layout = false;
    for (unsigned c = 0; c < layout->channels && c < 16; ++c)
        spatial_layout |= layout->speakers[c] >= STHD_TFL;
    if (!spatial_layout)
        return sthd_render(f, layout, gain, out, capacity);
    if (motion->channels != f->element_channels ||
        motion->valid_samples != ((uint64_t(1) << f->samples) - 1))
        return STHD_UNKNOWN_LAYOUT;
    bool constant = true;
    for (unsigned n = 1; n < f->samples; ++n)
        if (std::memcmp(motion->positions[0], motion->positions[n],
                        motion->channels * sizeof(STHDPosition))) {
            constant = false;
            break;
        }
    if (constant) {
        STHDFrame fixed = *f;
        fixed.positions_valid = 1;
        std::copy_n(motion->positions[0], motion->channels, fixed.positions);
        return sthd_render(&fixed, layout, gain, out, capacity);
    }
    if (capacity < size_t(f->samples) * layout->channels)
        return STHD_BUFFER_TOO_SMALL;
    STHDFrame sample = *f;
    sample.samples = 1;
    sample.positions_valid = 1;
    for (unsigned n = 0; n < f->samples; ++n) {
        for (unsigned layer = 0; layer < f->presentations; ++layer)
            std::copy_n(f->pcm[layer] + n * f->channels[layer], f->channels[layer], sample.pcm[layer]);
        std::copy_n(motion->positions[n], motion->channels, sample.positions);
        auto status = sthd_render(&sample, layout, gain, out + size_t(n) * layout->channels,
                                  capacity - size_t(n) * layout->channels);
        if (status != STHD_OK)
            return status;
    }
    return STHD_OK;
} catch (...) {
    return STHD_OUT_OF_MEMORY;
}
}
