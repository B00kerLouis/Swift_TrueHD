// SPDX-License-Identifier: AGPL-3.0-only
#include "AudioBackend.hpp"
#include <cmath>
#include <cstring>
#include <new>
namespace {
unsigned mask(const STHDLayout &l) {
    unsigned m = 0;
    for (unsigned i = 0; i < l.channels && i < 16; ++i) {
        if (unsigned(l.speakers[i]) >= 16)
            return 0;
        m |= 1U << unsigned(l.speakers[i]);
    }
    return m;
}
bool valid_layout(const STHDLayout &layout) { return sthd_audio::reported_layout_valid(layout); }
} // namespace
struct STHDAudioOutput {
    sthd_audio::Ring ring;
    std::unique_ptr<sthd_audio::Driver> driver;
    explicit STHDAudioOutput(const STHDAudioPlan &p)
        : ring(p.mode == STHD_AUDIO_POSITIONAL_OBJECTS ? p.object_count + 1 : p.layout.channels) {
        driver = sthd_audio::make_native(ring, p);
    }
};
extern "C" {
STHDStatus sthd_presentation(const STHDFrame *f, STHDPresentationKind kind,
                             STHDDecodedPresentation *v) {
    if (!f || !v || f->samples < 1 || f->samples > 40 || f->sample_rate != 48000 ||
        unsigned(kind) >= f->presentations || unsigned(kind) > 3)
        return STHD_INVALID_ARGUMENT;
    STHDDecodedPresentation out{};
    out.samples = f->samples;
    out.sample_rate = f->sample_rate;
    if (kind == STHD_PRESENTATION_IMMERSIVE) {
        if (!f->positions_valid ||
            (f->element_channels != 12 && f->element_channels != 14 && f->element_channels != 16) ||
            f->channels[3] != f->element_channels)
            return STHD_INVALID_ARGUMENT;
        out.bed_layout.channels = 1;
        out.bed_layout.speakers[0] = STHD_LFE;
        out.bed_pcm = f->pcm[3];
        out.bed_sample_stride = f->element_channels;
        out.object_count = f->element_channels - 1;
        for (unsigned c = 1; c < f->element_channels; ++c) {
            auto p = f->positions[c];
            if (!std::isfinite(p.x) || !std::isfinite(p.y) || !std::isfinite(p.z))
                return STHD_INVALID_ARGUMENT;
            out.objects[c - 1] = {c, f->element_channels, p, f->pcm[3] + c};
        }
    } else {
        sthd_layout_named(kind == STHD_PRESENTATION_STEREO
                              ? "2.0"
                              : (kind == STHD_PRESENTATION_51 ? "5.1" : "7.1"),
                          &out.bed_layout);
        if (f->channels[unsigned(kind)] != out.bed_layout.channels)
            return STHD_INVALID_ARGUMENT;
        out.bed_pcm = f->pcm[unsigned(kind)];
        out.bed_sample_stride = out.bed_layout.channels;
    }
    *v = out;
    return STHD_OK;
}
const char *sthd_audio_backend_name(STHDAudioBackend b) {
    const char *names[] = {"unavailable",           "CoreAudio", "WASAPI",
                           "Windows Spatial Audio", "PipeWire",  "ALSA"};
    return unsigned(b) < 6 ? names[unsigned(b)] : "unknown";
}
STHDStatus sthd_audio_capabilities(STHDAudioCapabilities *c) try {
    if (!c)
        return STHD_INVALID_ARGUMENT;
    *c = STHDAudioCapabilities{};
    sthd_audio::native_capabilities(*c);
    return c->pcm_available || c->spatial_available ? STHD_OK : STHD_DEVICE_UNAVAILABLE;
} catch (...) {
    return STHD_DEVICE_UNAVAILABLE;
}
STHDStatus sthd_audio_plan(const STHDFrame *f, const STHDAudioCapabilities *c,
                           const STHDLayout *explicit_layout, int fallback, STHDAudioPlan *p) {
    if (!f || !c || !p || f->presentations < 3 || f->presentations > 4 || f->samples < 1 ||
        f->samples > 40)
        return STHD_INVALID_ARGUMENT;
    if (explicit_layout && !valid_layout(*explicit_layout))
        return STHD_UNKNOWN_LAYOUT;
    STHDDecodedPresentation view{};
    auto presentation_status = sthd_presentation(
        f, f->presentations == 4 ? STHD_PRESENTATION_IMMERSIVE : STHD_PRESENTATION_71, &view);
    if (presentation_status != STHD_OK)
        return presentation_status;
    STHDAudioPlan out{};
    out.room_half_width_m = out.room_half_depth_m = out.room_height_m = 1;
    out.native_device_id = c->native_device_id;
    std::memcpy(out.endpoint, c->endpoint, sizeof(out.endpoint));
    out.presentation = f->presentations == 4 ? STHD_PRESENTATION_IMMERSIVE : STHD_PRESENTATION_71;
    if (f->presentations == 4 && !explicit_layout && c->spatial_available) {
        if (f->element_channels >= 12 && f->element_channels <= 16 &&
            c->max_dynamic_objects >= f->element_channels - 1 &&
            (c->spatial_speaker_mask & (1U << STHD_LFE))) {
            out.backend = STHD_AUDIO_WINDOWS_SPATIAL;
            out.mode = STHD_AUDIO_POSITIONAL_OBJECTS;
            out.object_count = f->element_channels - 1;
            out.layout.channels = 1;
            out.layout.speakers[0] = STHD_LFE;
            *p = out;
            return STHD_OK;
        }
        const char *names[] = {"7.1.4", "5.1.4", "7.1", "5.1", "5.1(back)", "2.0"};
        for (auto name : names) {
            STHDLayout l{};
            sthd_layout_named(name, &l);
            if ((mask(l) & c->spatial_speaker_mask) == mask(l)) {
                out.backend = STHD_AUDIO_WINDOWS_SPATIAL;
                out.mode = STHD_AUDIO_STATIC_OBJECTS;
                out.layout = l;
                *p = out;
                return STHD_OK;
            }
        }
    }
    // Mac/Linux render immersive feeds locally. Windows requires an explicit
    // choice before falling back from Spatial Audio to a PCM endpoint.
    if (f->presentations == 4 && c->pcm_backend == STHD_AUDIO_WASAPI && !explicit_layout &&
        !fallback)
        return STHD_UNSUPPORTED_OUTPUT;
    if (!c->pcm_available)
        return STHD_DEVICE_UNAVAILABLE;
    if (explicit_layout) {
        if (explicit_layout->channels != c->pcm_channels)
            return STHD_UNSUPPORTED_OUTPUT;
        if (c->pcm_layout_valid && mask(*explicit_layout) != mask(c->pcm_layout))
            return STHD_UNSUPPORTED_OUTPUT;
        out.layout = *explicit_layout;
        // Use actual endpoint ordering when its labels are known.
        if (c->pcm_layout_valid)
            out.layout = c->pcm_layout;
    } else {
        if (!c->pcm_layout_valid)
            return STHD_UNKNOWN_LAYOUT;
        out.layout = c->pcm_layout;
    }
    out.backend = c->pcm_backend;
    out.mode = STHD_AUDIO_PCM;
    *p = out;
    return STHD_OK;
}
STHDAudioOutput *sthd_audio_open(const STHDAudioPlan *p, char *error, size_t n) try {
    if (!p || !error || !n)
        return nullptr;
    error[0] = 0;
    if (unsigned(p->mode) > 2)
        return nullptr;
    if (p->mode == STHD_AUDIO_POSITIONAL_OBJECTS &&
        (!std::isfinite(p->room_half_width_m) || !std::isfinite(p->room_half_depth_m) ||
         !std::isfinite(p->room_height_m) || p->room_half_width_m <= 0 ||
         p->room_half_depth_m <= 0 || p->room_height_m <= 0)) {
        std::snprintf(error, n, "invalid room dimensions");
        return nullptr;
    }
    if ((p->mode == STHD_AUDIO_POSITIONAL_OBJECTS && (p->object_count < 1 || p->object_count > 15 ||
                                                      p->backend != STHD_AUDIO_WINDOWS_SPATIAL)) ||
        (p->mode != STHD_AUDIO_POSITIONAL_OBJECTS && !valid_layout(p->layout))) {
        std::snprintf(error, n, "invalid audio output plan");
        return nullptr;
    }
    auto o = std::make_unique<STHDAudioOutput>(*p);
    if (!o->driver) {
        std::snprintf(error, n, "native backend unavailable in this build");
        return nullptr;
    }
    auto s = o->driver->open();
    if (s != STHD_OK) {
        std::snprintf(error, n, "%s: %s", sthd_status_string(s), o->driver->error);
        return nullptr;
    }
    return o.release();
} catch (...) {
    if (error && n)
        std::snprintf(error, n, "audio initialization failed");
    return nullptr;
}
STHDStatus sthd_audio_write(STHDAudioOutput *o, const STHDFrame *f, float gain,
                            uint32_t timeout) try {
    if (!o || !f || !std::isfinite(gain) || gain < 0 || o->ring.draining.load())
        return STHD_INVALID_ARGUMENT;
    if (o->ring.stopping.load())
        return STHD_CANCELLED;
    auto failure = o->ring.failure.load();
    if (failure != STHD_OK)
        return failure;
    std::array<float, 640> pcm{};
    if (o->driver->plan.mode == STHD_AUDIO_POSITIONAL_OBJECTS) {
        STHDDecodedPresentation v{};
        auto s = sthd_presentation(f, STHD_PRESENTATION_IMMERSIVE, &v);
        if (s != STHD_OK)
            return s;
        if (v.object_count != o->driver->plan.object_count)
            return STHD_UNSUPPORTED_OUTPUT;
        if (!o->ring.positions_ready.load()) {
            for (unsigned i = 0; i < v.object_count; ++i)
                o->ring.positions[i + 1] = v.objects[i].position;
            o->ring.positions_ready.store(true, std::memory_order_release);
        } else
            for (unsigned i = 0; i < v.object_count; ++i) {
                auto a = o->ring.positions[i + 1], b = v.objects[i].position;
                if (a.x != b.x || a.y != b.y || a.z != b.z)
                    return STHD_UNSUPPORTED_OUTPUT;
            }
        for (unsigned i = 0; i < f->samples * o->ring.channels; ++i)
            pcm[i] = float(double(f->pcm[3][i]) * double(gain) / 8388608.0);
    } else {
        auto s = sthd_render(f, &o->driver->plan.layout, gain, pcm.data(), pcm.size());
        if (s != STHD_OK)
            return s;
    }
    auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout);
    while (!o->ring.push(pcm.data(), f->samples)) {
        if (o->ring.stopping.load())
            return STHD_CANCELLED;
        auto s = o->ring.failure.load();
        if (s != STHD_OK)
            return s;
        if (std::chrono::steady_clock::now() >= end)
            return STHD_TIMEOUT;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    if (!o->ring.started.load() && o->ring.available() >= 2048) {
        auto s = o->driver->start();
        if (s != STHD_OK)
            return s;
        o->ring.started.store(true);
    }
    return o->ring.failure.load();
} catch (...) {
    return STHD_AUDIO_FAILURE;
}
STHDStatus sthd_audio_drain(STHDAudioOutput *o, uint32_t timeout) try {
    if (!o)
        return STHD_INVALID_ARGUMENT;
    if (o->ring.stopping.load())
        return STHD_CANCELLED;
    o->ring.draining.store(true);
    if (!o->ring.started.load()) {
        auto s = o->driver->start();
        if (s != STHD_OK)
            return s;
        o->ring.started.store(true);
    }
    auto result = o->driver->finish(timeout);
    return o->ring.stopping.load() ? STHD_CANCELLED : result;
} catch (...) {
    return STHD_AUDIO_FAILURE;
}
STHDStatus sthd_audio_stats(const STHDAudioOutput *o, STHDAudioStats *s) {
    if (!o || !s)
        return STHD_INVALID_ARGUMENT;
    s->submitted_frames = o->ring.write.load();
    s->consumed_frames = o->ring.read.load();
    s->underruns = o->ring.underruns.load();
    s->queue_capacity_frames = uint32_t(sthd_audio::Ring::capacity);
    return STHD_OK;
}
const char *sthd_audio_error(const STHDAudioOutput *o) {
    if (!o)
        return "null audio output";
    const auto status = o->ring.failure.load(std::memory_order_acquire);
    if (status == STHD_OK)
        return "";
    return o->driver->error[0] ? o->driver->error : sthd_status_string(status);
}
uint64_t sthd_audio_underruns(const STHDAudioOutput *o) { return o ? o->ring.underruns.load() : 0; }
void sthd_audio_cancel(STHDAudioOutput *o) {
    if (o)
        o->ring.stopping.store(true);
}
void sthd_audio_close(STHDAudioOutput *o) {
    if (o)
        o->ring.stopping.store(true);
    delete o;
}
}
