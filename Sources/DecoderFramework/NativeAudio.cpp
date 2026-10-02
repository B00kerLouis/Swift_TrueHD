// SPDX-License-Identifier: AGPL-3.0-only
#include "AudioBackend.hpp"
#include <cmath>
#include <cstring>
#include <stdexcept>
#if defined(__APPLE__) && !defined(STHD_DISABLE_NATIVE_DEVICE)
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#elif defined(_WIN32) && !defined(STHD_DISABLE_NATIVE_DEVICE)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <audioclient.h>
#include <ks.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <spatialaudioclient.h>
#include <windows.h>
#endif
namespace sthd_audio {
#if defined(__APPLE__) && !defined(STHD_DISABLE_NATIVE_DEVICE)
void native_capabilities(STHDAudioCapabilities &c) {
    AudioDeviceID id = 0;
    UInt32 n = sizeof(id);
    AudioObjectPropertyAddress a{kAudioHardwarePropertyDefaultOutputDevice,
                                 kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &n, &id) != noErr ||
        !id)
        return;
    c.pcm_backend = STHD_AUDIO_COREAUDIO;
    c.pcm_available = 1;
    c.native_device_id = id;
    c.pcm_layout_valid =
        sthd_default_device_layout(&c.pcm_layout, c.endpoint, sizeof(c.endpoint)) == STHD_OK;
    a = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
         kAudioObjectPropertyElementMain};
    double rate = 0;
    n = sizeof(rate);
    if (AudioObjectGetPropertyData(id, &a, 0, nullptr, &n, &rate) == noErr)
        c.pcm_sample_rate = uint32_t(rate);
    a = {kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput,
         kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyDataSize(id, &a, 0, nullptr, &n) != noErr ||
        n < offsetof(AudioBufferList, mBuffers))
        return;
    std::vector<uint8_t> b(n);
    if (AudioObjectGetPropertyData(id, &a, 0, nullptr, &n, b.data()) != noErr)
        return;
    auto *l = reinterpret_cast<AudioBufferList *>(b.data());
    if (b.size() < offsetof(AudioBufferList, mBuffers) + l->mNumberBuffers * sizeof(AudioBuffer))
        return;
    for (unsigned i = 0; i < l->mNumberBuffers; ++i)
        c.pcm_channels += l->mBuffers[i].mNumberChannels;
}
struct CoreAudioDriver final : Driver {
    AudioUnit unit = nullptr;
    std::vector<float> scratch;
    bool observing_default = false, observing_layout = false, observing_preferred = false,
         observing_stereo = false;
    AudioObjectPropertyAddress default_address{kAudioHardwarePropertyDefaultOutputDevice,
                                               kAudioObjectPropertyScopeGlobal,
                                               kAudioObjectPropertyElementMain};
    AudioObjectPropertyAddress layout_address{kAudioDevicePropertyStreamConfiguration,
                                              kAudioObjectPropertyScopeOutput,
                                              kAudioObjectPropertyElementMain};
    AudioObjectPropertyAddress preferred_address{kAudioDevicePropertyPreferredChannelLayout,
                                                 kAudioObjectPropertyScopeOutput,
                                                 kAudioObjectPropertyElementMain};
    AudioObjectPropertyAddress stereo_address{kAudioDevicePropertyPreferredChannelsForStereo,
                                              kAudioObjectPropertyScopeOutput,
                                              kAudioObjectPropertyElementMain};
    static OSStatus changed(AudioObjectID, UInt32, const AudioObjectPropertyAddress *,
                            void *context) {
        static_cast<CoreAudioDriver *>(context)->ring.failure.store(STHD_DEVICE_UNAVAILABLE);
        return noErr;
    }
    CoreAudioDriver(Ring &r, const STHDAudioPlan &p) : Driver(r, p), scratch(4096 * r.channels) {}
    ~CoreAudioDriver() {
        if (observing_stereo)
            AudioObjectRemovePropertyListener(plan.native_device_id, &stereo_address, changed,
                                              this);
        if (observing_preferred)
            AudioObjectRemovePropertyListener(plan.native_device_id, &preferred_address, changed,
                                              this);
        if (observing_default)
            AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &default_address, changed,
                                              this);
        if (observing_layout)
            AudioObjectRemovePropertyListener(plan.native_device_id, &layout_address, changed,
                                              this);
        if (unit) {
            AudioOutputUnitStop(unit);
            AudioUnitUninitialize(unit);
            AudioComponentInstanceDispose(unit);
        }
    }
    static OSStatus callback(void *data, AudioUnitRenderActionFlags *, const AudioTimeStamp *,
                             UInt32, UInt32 frames, AudioBufferList *buffers) {
        auto &d = *static_cast<CoreAudioDriver *>(data);
        if (frames > 4096 || !buffers) {
            d.ring.failure.store(STHD_AUDIO_FAILURE);
            return kAudio_ParamError;
        }
        if (d.ring.failure.load() != STHD_OK) {
            for (unsigned b = 0; b < buffers->mNumberBuffers; ++b)
                if (buffers->mBuffers[b].mData)
                    std::memset(buffers->mBuffers[b].mData, 0, buffers->mBuffers[b].mDataByteSize);
            return noErr;
        }
        d.ring.consume(d.scratch.data(), frames);
        unsigned channel = 0;
        for (unsigned b = 0; b < buffers->mNumberBuffers; ++b) {
            auto &v = buffers->mBuffers[b];
            if (!v.mData || channel + v.mNumberChannels > d.ring.channels ||
                v.mDataByteSize < size_t(frames) * v.mNumberChannels * sizeof(float)) {
                d.ring.failure.store(STHD_AUDIO_FAILURE);
                return kAudio_ParamError;
            }
            auto *dst = static_cast<float *>(v.mData);
            for (unsigned f = 0; f < frames; ++f)
                for (unsigned c = 0; c < v.mNumberChannels; ++c)
                    dst[size_t(f) * v.mNumberChannels + c] =
                        d.scratch[size_t(f) * d.ring.channels + channel + c];
            channel += v.mNumberChannels;
        }
        if (channel != d.ring.channels) {
            d.ring.failure.store(STHD_AUDIO_FAILURE);
            return kAudio_ParamError;
        }
        return noErr;
    }
    STHDStatus open() override {
        STHDAudioCapabilities current{};
        native_capabilities(current);
        if (current.native_device_id != plan.native_device_id ||
            current.pcm_channels != ring.channels) {
            std::snprintf(error, sizeof(error), "default output device changed");
            return STHD_DEVICE_UNAVAILABLE;
        }
        if (current.pcm_layout_valid)
            for (unsigned i = 0; i < ring.channels; ++i)
                if (current.pcm_layout.speakers[i] != plan.layout.speakers[i]) {
                    std::snprintf(error, sizeof(error), "device physical channel order changed");
                    return STHD_UNSUPPORTED_OUTPUT;
                }
        AudioComponentDescription description{kAudioUnitType_Output,
                                              kAudioUnitSubType_DefaultOutput,
                                              kAudioUnitManufacturer_Apple, 0, 0};
        auto component = AudioComponentFindNext(nullptr, &description);
        if (!component || AudioComponentInstanceNew(component, &unit) != noErr)
            return STHD_AUDIO_FAILURE;
        AudioStreamBasicDescription format{};
        format.mSampleRate = 48000;
        format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
        format.mBytesPerPacket = format.mBytesPerFrame = ring.channels * sizeof(float);
        format.mFramesPerPacket = 1;
        format.mChannelsPerFrame = ring.channels;
        format.mBitsPerChannel = 32;
        AURenderCallbackStruct cb{callback, this};
        std::array<SInt32, 16> map{};
        for (unsigned i = 0; i < ring.channels; ++i)
            map[i] = SInt32(i);
        OSStatus result = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                               kAudioUnitScope_Input, 0, &format, sizeof(format));
        if (result == noErr)
            result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap,
                                          kAudioUnitScope_Output, 0, map.data(),
                                          UInt32(ring.channels * sizeof(SInt32)));
        if (result == noErr)
            result = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                          kAudioUnitScope_Input, 0, &cb, sizeof(cb));
        if (result == noErr)
            result = AudioUnitInitialize(unit);
        if (result != noErr) {
            std::snprintf(error, sizeof(error), "CoreAudio format/map initialization failed (%d)",
                          int(result));
            return STHD_AUDIO_FAILURE;
        }
        observing_default = AudioObjectAddPropertyListener(
                                kAudioObjectSystemObject, &default_address, changed, this) == noErr;
        observing_layout = AudioObjectAddPropertyListener(plan.native_device_id, &layout_address,
                                                          changed, this) == noErr;
        if (AudioObjectHasProperty(plan.native_device_id, &preferred_address)) {
            observing_preferred =
                AudioObjectAddPropertyListener(plan.native_device_id, &preferred_address, changed,
                                               this) == noErr;
            if (!observing_preferred)
                return STHD_AUDIO_FAILURE;
        }
        if (AudioObjectHasProperty(plan.native_device_id, &stereo_address)) {
            observing_stereo = AudioObjectAddPropertyListener(
                                   plan.native_device_id, &stereo_address, changed, this) == noErr;
            if (!observing_stereo)
                return STHD_AUDIO_FAILURE;
        }
        if (!observing_default || !observing_layout) {
            std::snprintf(error, sizeof(error),
                          "cannot monitor default device/channel layout changes");
            return STHD_AUDIO_FAILURE;
        }
        return STHD_OK;
    }
    STHDStatus start() override {
        return AudioOutputUnitStart(unit) == noErr ? STHD_OK : STHD_AUDIO_FAILURE;
    }
    STHDStatus finish(uint32_t timeout) override {
        auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout);
        if (!wait_empty(ring, timeout))
            return ring.failure.load() != STHD_OK ? ring.failure.load() : STHD_TIMEOUT;
        Float64 latency = 0, rate = 48000;
        UInt32 n = sizeof(latency);
        AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency,
                             &n);
        AudioObjectPropertyAddress rate_address{kAudioDevicePropertyNominalSampleRate,
                                                kAudioObjectPropertyScopeGlobal,
                                                kAudioObjectPropertyElementMain};
        n = sizeof(rate);
        AudioObjectGetPropertyData(plan.native_device_id, &rate_address, 0, nullptr, &n, &rate);
        auto samples = [](AudioObjectID id, AudioObjectPropertySelector selector,
                          AudioObjectPropertyScope scope) {
            AudioObjectPropertyAddress address{selector, scope, kAudioObjectPropertyElementMain};
            UInt32 value = 0, size = sizeof(value);
            return AudioObjectGetPropertyData(id, &address, 0, nullptr, &size, &value) == noErr
                       ? value
                       : 0U;
        };
        uint64_t hardware =
            samples(plan.native_device_id, kAudioDevicePropertyLatency,
                    kAudioObjectPropertyScopeOutput) +
            uint64_t(samples(plan.native_device_id, kAudioDevicePropertySafetyOffset,
                             kAudioObjectPropertyScopeOutput));
        hardware += samples(plan.native_device_id, kAudioDevicePropertyBufferFrameSize,
                            kAudioObjectPropertyScopeGlobal);
        std::array<AudioStreamID, 128> streams{};
        AudioObjectPropertyAddress stream_address{kAudioDevicePropertyStreams,
                                                  kAudioObjectPropertyScopeOutput,
                                                  kAudioObjectPropertyElementMain};
        n = sizeof(streams);
        UInt32 stream_latency = 0;
        if (AudioObjectGetPropertyData(plan.native_device_id, &stream_address, 0, nullptr, &n,
                                       streams.data()) == noErr)
            for (unsigned i = 0; i < n / sizeof(AudioStreamID); ++i)
                stream_latency =
                    std::max(stream_latency, samples(streams[i], kAudioStreamPropertyLatency,
                                                     kAudioObjectPropertyScopeGlobal));
        hardware += stream_latency;
        // Account for device/stream latency as well as the AudioUnit converter;
        // FIFO consumption alone is not proof that the final DAC frame played.
        double tail = latency + double(hardware) / (rate > 0 ? rate : 48000) + 0.02;
        if (!std::isfinite(tail) || tail < 0 || tail > 3600)
            return STHD_AUDIO_FAILURE;
        auto duration = std::chrono::milliseconds(uint64_t(tail * 1000 + 1));
        if (std::chrono::steady_clock::now() + duration > deadline)
            return STHD_TIMEOUT;
        auto tail_end = std::chrono::steady_clock::now() + duration;
        while (std::chrono::steady_clock::now() < tail_end) {
            if (ring.stopping.load())
                return STHD_CANCELLED;
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        return ring.failure.load();
    }
};
std::unique_ptr<Driver> make_native(Ring &r, const STHDAudioPlan &p) {
    if (p.backend == STHD_AUDIO_COREAUDIO)
        return std::make_unique<CoreAudioDriver>(r, p);
    return {};
}
#elif defined(_WIN32) && !defined(STHD_DISABLE_NATIVE_DEVICE)
template <class T> struct Com {
    T *p = nullptr;
    ~Com() {
        if (p)
            p->Release();
    }
    T *operator->() const { return p; }
    T **address() { return &p; }
};
struct Apartment {
    HRESULT result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    ~Apartment() {
        if (SUCCEEDED(result))
            CoUninitialize();
    }
};
static AudioObjectType object_type(STHDSpeaker s) {
    static const AudioObjectType types[] = {
        AudioObjectType_FrontLeft,     AudioObjectType_FrontRight,  AudioObjectType_FrontCenter,
        AudioObjectType_LowFrequency,  AudioObjectType_BackLeft,    AudioObjectType_BackRight,
        AudioObjectType_SideLeft,      AudioObjectType_SideRight,   AudioObjectType_TopFrontLeft,
        AudioObjectType_TopFrontRight, AudioObjectType_TopBackLeft, AudioObjectType_TopBackRight};
    return unsigned(s) < 12 ? types[unsigned(s)] : AudioObjectType_None;
}
static bool endpoint(Com<IMMDeviceEnumerator> &e, Com<IMMDevice> &d) {
    return SUCCEEDED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                      __uuidof(IMMDeviceEnumerator),
                                      reinterpret_cast<void **>(e.address()))) &&
           SUCCEEDED(e->GetDefaultAudioEndpoint(eRender, eConsole, d.address()));
}
void native_capabilities(STHDAudioCapabilities &c) {
    Apartment a;
    if (FAILED(a.result) && a.result != RPC_E_CHANGED_MODE)
        return;
    Com<IMMDeviceEnumerator> e;
    Com<IMMDevice> d;
    if (!endpoint(e, d))
        return;
    c.pcm_backend = STHD_AUDIO_WASAPI;
    c.pcm_available = 1;
    c.pcm_layout_valid =
        sthd_default_device_layout(&c.pcm_layout, c.endpoint, sizeof(c.endpoint)) == STHD_OK;
    LPWSTR id = nullptr;
    if (SUCCEEDED(d->GetId(&id))) {
        WideCharToMultiByte(CP_UTF8, 0, id, -1, c.endpoint, sizeof(c.endpoint), nullptr, nullptr);
        CoTaskMemFree(id);
    }
    Com<IAudioClient> pcm;
    if (SUCCEEDED(d->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                              reinterpret_cast<void **>(pcm.address())))) {
        WAVEFORMATEX *f = nullptr;
        if (SUCCEEDED(pcm->GetMixFormat(&f))) {
            c.pcm_channels = f->nChannels;
            c.pcm_sample_rate = f->nSamplesPerSec;
            CoTaskMemFree(f);
        }
    }
    Com<ISpatialAudioClient> spatial;
    if (SUCCEEDED(d->Activate(__uuidof(ISpatialAudioClient), CLSCTX_ALL, nullptr,
                              reinterpret_cast<void **>(spatial.address())))) {
        AudioObjectType mask = AudioObjectType_None;
        UINT32 objects = 0;
        if (SUCCEEDED(spatial->GetNativeStaticObjectTypeMask(&mask)) &&
            SUCCEEDED(spatial->GetMaxDynamicObjectCount(&objects))) {
            c.spatial_available = 1;
            c.max_dynamic_objects = objects;
            for (unsigned s = 0; s < 12; ++s)
                if (unsigned(mask) & unsigned(object_type(STHDSpeaker(s))))
                    c.spatial_speaker_mask |= 1U << s;
        }
    }
}
struct WindowsDriver final : Driver {
    std::thread worker;
    std::atomic<bool> ready{false}, go{false}, done{false};
    std::atomic<STHDStatus> opened{STHD_OK};
    WindowsDriver(Ring &r, const STHDAudioPlan &p) : Driver(r, p) {}
    ~WindowsDriver() {
        ring.stopping.store(true);
        if (worker.joinable())
            worker.join();
    }
    void check(HRESULT h) {
        if (FAILED(h)) {
            std::snprintf(error, sizeof(error), "Windows audio HRESULT 0x%08lx",
                          static_cast<unsigned long>(h));
            throw std::runtime_error(error);
        }
    }
    void run() {
        try {
            Apartment a;
            check(a.result);
            Com<IMMDeviceEnumerator> e;
            Com<IMMDevice> d;
            if (!endpoint(e, d))
                throw std::runtime_error("default endpoint unavailable");
            LPWSTR device_id = nullptr;
            check(d->GetId(&device_id));
            char current_id[256]{};
            WideCharToMultiByte(CP_UTF8, 0, device_id, -1, current_id, sizeof(current_id), nullptr,
                                nullptr);
            CoTaskMemFree(device_id);
            if (std::strcmp(current_id, plan.endpoint))
                throw std::runtime_error("default endpoint changed");
            if (plan.backend == STHD_AUDIO_WASAPI)
                run_pcm(d);
            else
                run_spatial(d);
        } catch (const std::exception &ex) {
            if (!error[0])
                std::snprintf(error, sizeof(error), "%s", ex.what());
            opened.store(STHD_AUDIO_FAILURE);
            ring.failure.store(STHD_AUDIO_FAILURE);
            ready.store(true);
        }
    }
    struct Event {
        HANDLE handle = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        ~Event() {
            if (handle)
                CloseHandle(handle);
        }
    };
    bool wait_start() {
        ready.store(true);
        while (!go.load() && !ring.stopping.load())
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        return !ring.stopping.load();
    }
    void run_pcm(Com<IMMDevice> &d) {
        Com<IAudioClient> client;
        check(d->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                          reinterpret_cast<void **>(client.address())));
        WAVEFORMATEXTENSIBLE format{};
        auto &f = format.Format;
        f.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
        f.nChannels = WORD(ring.channels);
        f.nSamplesPerSec = 48000;
        f.wBitsPerSample = 32;
        f.nBlockAlign = WORD(ring.channels * 4);
        f.nAvgBytesPerSec = 48000 * f.nBlockAlign;
        f.cbSize = 22;
        format.Samples.wValidBitsPerSample = 32;
        format.dwChannelMask = sthd_wave_channel_mask(&plan.layout);
        format.SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
        WAVEFORMATEX *current = nullptr;
        check(client->GetMixFormat(&current));
        uint32_t current_mask =
            current->wFormatTag == WAVE_FORMAT_EXTENSIBLE && current->cbSize >= 22
                ? reinterpret_cast<WAVEFORMATEXTENSIBLE *>(current)->dwChannelMask
                : (current->nChannels == 2 ? 3U : 0U);
        // An explicitly labelled discrete endpoint may legitimately use mask
        // zero. Retain its physical slot order without inventing speaker bits.
        if (!current_mask)
            format.dwChannelMask = 0;
        bool same =
            current->nChannels == format.Format.nChannels && current_mask == format.dwChannelMask;
        CoTaskMemFree(current);
        if (!same)
            throw std::runtime_error("WASAPI endpoint layout changed");
        check(client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                                 AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
                                     AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                                     AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                                 0, 0, &f, nullptr));
        Event event;
        if (!event.handle)
            throw std::runtime_error("cannot create render event");
        check(client->SetEventHandle(event.handle));
        UINT32 frames = 0;
        check(client->GetBufferSize(&frames));
        Com<IAudioRenderClient> render;
        check(client->GetService(__uuidof(IAudioRenderClient),
                                 reinterpret_cast<void **>(render.address())));
        if (!wait_start())
            return;
        check(client->Start());
        while (!ring.stopping.load()) {
            if (WaitForSingleObject(event.handle, 100) == WAIT_FAILED)
                throw std::runtime_error("render event failed");
            UINT32 padding = 0;
            check(client->GetCurrentPadding(&padding));
            if (ring.draining.load() && ring.available() == 0) {
                if (padding == 0) {
                    done.store(true);
                    break;
                }
                continue;
            }
            if (padding >= frames)
                continue;
            BYTE *buffer = nullptr;
            UINT32 count = frames - padding;
            check(render->GetBuffer(count, &buffer));
            ring.consume(reinterpret_cast<float *>(buffer), count);
            check(render->ReleaseBuffer(count, 0));
        }
        client->Stop();
    }
    void run_spatial(Com<IMMDevice> &d) {
        Com<ISpatialAudioClient> client;
        check(d->Activate(__uuidof(ISpatialAudioClient), CLSCTX_ALL, nullptr,
                          reinterpret_cast<void **>(client.address())));
        WAVEFORMATEX format{};
        format.wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
        format.nChannels = 1;
        format.nSamplesPerSec = 48000;
        format.wBitsPerSample = 32;
        format.nBlockAlign = 4;
        format.nAvgBytesPerSec = 192000;
        check(client->IsAudioObjectFormatSupported(&format));
        Event event;
        if (!event.handle)
            throw std::runtime_error("cannot create spatial render event");
        unsigned mask = 0;
        if (plan.mode == STHD_AUDIO_POSITIONAL_OBJECTS)
            mask = AudioObjectType_LowFrequency;
        else
            for (unsigned i = 0; i < plan.layout.channels; ++i) {
                auto t = object_type(plan.layout.speakers[i]);
                if (t == AudioObjectType_None)
                    throw std::runtime_error("unsupported static object position");
                mask |= unsigned(t);
            }
        SpatialAudioObjectRenderStreamActivationParams params{};
        params.ObjectFormat = &format;
        params.StaticObjectTypeMask = AudioObjectType(mask);
        params.MinDynamicObjectCount = params.MaxDynamicObjectCount =
            plan.mode == STHD_AUDIO_POSITIONAL_OBJECTS ? plan.object_count : 0;
        params.Category = AudioCategory_Media;
        params.EventHandle = event.handle;
        PROPVARIANT activation{};
        activation.vt = VT_BLOB;
        activation.blob.cbSize = sizeof(params);
        activation.blob.pBlobData = reinterpret_cast<BYTE *>(&params);
        Com<ISpatialAudioObjectRenderStream> stream;
        check(client->ActivateSpatialAudioStream(&activation,
                                                 __uuidof(ISpatialAudioObjectRenderStream),
                                                 reinterpret_cast<void **>(stream.address())));
        std::array<Com<ISpatialAudioObject>, 16> objects;
        for (unsigned i = 0; i < ring.channels; ++i)
            check(stream->ActivateSpatialAudioObject(
                plan.mode == STHD_AUDIO_POSITIONAL_OBJECTS
                    ? (i ? AudioObjectType_Dynamic : AudioObjectType_LowFrequency)
                    : object_type(plan.layout.speakers[i]),
                objects[i].address()));
        UINT32 maximum = 0;
        check(client->GetMaxFrameCount(&format, &maximum));
        if (!maximum || maximum > 16384)
            throw std::runtime_error("invalid spatial quantum size");
        std::vector<float> scratch(size_t(maximum) * ring.channels);
        if (!wait_start())
            return;
        check(stream->Start());
        bool ended = false;
        while (!ring.stopping.load()) {
            const DWORD wake = WaitForSingleObject(event.handle, 100);
            if (wake == WAIT_FAILED)
                throw std::runtime_error("spatial render event failed");
            if (wake != WAIT_OBJECT_0)
                continue;
            UINT32 available = 0, frames = 0;
            check(stream->BeginUpdatingAudioObjects(&available, &frames));
            if (frames > maximum) {
                stream->EndUpdatingAudioObjects();
                throw std::runtime_error("spatial quantum exceeds negotiated size");
            }
            unsigned got = ring.pop(scratch.data(), frames);
            std::fill(scratch.data() + size_t(got) * ring.channels,
                      scratch.data() + size_t(frames) * ring.channels, 0.f);
            if (got < frames && !ring.draining.load())
                ring.underruns.fetch_add(1);
            for (unsigned i = 0; i < ring.channels; ++i) {
                BYTE *buffer = nullptr;
                UINT32 bytes = 0;
                check(objects[i]->GetBuffer(&buffer, &bytes));
                if (bytes < size_t(frames) * sizeof(float))
                    throw std::runtime_error("short spatial object buffer");
                auto *dst = reinterpret_cast<float *>(buffer);
                for (unsigned f = 0; f < frames; ++f)
                    dst[f] = scratch[size_t(f) * ring.channels + i];
                if (plan.mode == STHD_AUDIO_POSITIONAL_OBJECTS && i) {
                    auto p = ring.positions[i];
                    check(objects[i]->SetPosition(p.x * plan.room_half_width_m,
                                                  p.z * plan.room_height_m,
                                                  -p.y * plan.room_half_depth_m));
                }
                if (ring.draining.load() && ring.available() == 0) {
                    check(objects[i]->SetEndOfStream(got));
                    ended = true;
                }
            }
            check(stream->EndUpdatingAudioObjects());
            if (ended) {
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
                done.store(true);
                break;
            }
        }
        stream->Stop();
    }
    STHDStatus open() override {
        worker = std::thread([this] { run(); });
        auto end = std::chrono::steady_clock::now() + std::chrono::seconds(5);
        while (!ready.load()) {
            if (std::chrono::steady_clock::now() >= end) {
                ring.stopping.store(true);
                return STHD_TIMEOUT;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        return opened.load();
    }
    STHDStatus start() override {
        go.store(true);
        return opened.load();
    }
    STHDStatus finish(uint32_t timeout) override {
        auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout);
        while (!done.load()) {
            if (ring.stopping.load())
                return STHD_CANCELLED;
            if (ring.failure.load() != STHD_OK)
                return ring.failure.load();
            if (std::chrono::steady_clock::now() >= end)
                return STHD_TIMEOUT;
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        return STHD_OK;
    }
};
std::unique_ptr<Driver> make_native(Ring &r, const STHDAudioPlan &p) {
    if (p.backend == STHD_AUDIO_WASAPI || p.backend == STHD_AUDIO_WINDOWS_SPATIAL)
        return std::make_unique<WindowsDriver>(r, p);
    return {};
}
#else
void native_capabilities(STHDAudioCapabilities &c) {
#if defined(STHD_HAVE_PIPEWIRE) && !defined(STHD_DISABLE_NATIVE_DEVICE)
    (void)pipewire_capabilities(c);
#else
    (void)c;
#endif
}
std::unique_ptr<Driver> make_native(Ring &r, const STHDAudioPlan &p) {
#if defined(STHD_HAVE_PIPEWIRE) && !defined(STHD_DISABLE_NATIVE_DEVICE)
    if (p.backend == STHD_AUDIO_PIPEWIRE)
        return make_pipewire(r, p);
#else
    (void)r;
    (void)p;
#endif
    return {};
}
#endif
} // namespace sthd_audio
