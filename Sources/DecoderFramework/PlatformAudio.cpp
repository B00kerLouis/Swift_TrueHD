// SPDX-License-Identifier: AGPL-3.0-only
#include "AudioBackend.hpp"
#include "include/TrueHDDecoder.h"
#include <cstdio>
#include <cstring>
#include <new>
#include <vector>
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
#include <windows.h>
#elif defined(STHD_HAVE_ALSA) && !defined(STHD_DISABLE_NATIVE_DEVICE)
#include <alsa/asoundlib.h>
#endif
namespace {
[[maybe_unused]] STHDStatus checked(STHDLayout &l) {
    const char *names[] = {"2.0",   "5.1",   "7.1",   "5.1.2",     "5.1.4",       "7.1.2",
                           "7.1.4", "7.1.6", "9.1.6", "5.1(back)", "5.1.2(back)", "5.1.4(back)"};
    unsigned seen = 0;
    for (unsigned i = 0; i < l.channels; ++i) {
        unsigned x = unsigned(l.speakers[i]);
        if (x >= 16 || (seen & (1U << x)))
            return STHD_UNKNOWN_LAYOUT;
        seen |= 1U << x;
    }
    for (auto name : names) {
        STHDLayout standard{};
        sthd_layout_named(name, &standard);
        unsigned mask = 0;
        for (unsigned i = 0; i < standard.channels; ++i)
            mask |= 1U << unsigned(standard.speakers[i]);
        if (mask == seen)
            return STHD_OK;
    }
    return STHD_UNKNOWN_LAYOUT;
}
#if defined(__APPLE__) && !defined(STHD_DISABLE_NATIVE_DEVICE)
bool apple_label(AudioChannelLabel label, STHDSpeaker &s) {
    switch (label) {
    case kAudioChannelLabel_Left:
    case kAudioChannelLabel_HeadphonesLeft:
    case kAudioChannelLabel_BinauralLeft:
        s = STHD_FL;
        break;
    case kAudioChannelLabel_Right:
    case kAudioChannelLabel_HeadphonesRight:
    case kAudioChannelLabel_BinauralRight:
        s = STHD_FR;
        break;
    case kAudioChannelLabel_Center:
        s = STHD_FC;
        break;
    case kAudioChannelLabel_LFEScreen:
        s = STHD_LFE;
        break;
    case kAudioChannelLabel_LeftSurround:
    case kAudioChannelLabel_LeftSurroundDirect:
    case kAudioChannelLabel_LeftSideSurround:
        s = STHD_SL;
        break;
    case kAudioChannelLabel_RightSurround:
    case kAudioChannelLabel_RightSurroundDirect:
    case kAudioChannelLabel_RightSideSurround:
        s = STHD_SR;
        break;
    case kAudioChannelLabel_RearSurroundLeft:
        s = STHD_BL;
        break;
    case kAudioChannelLabel_RearSurroundRight:
        s = STHD_BR;
        break;
    case kAudioChannelLabel_LeftTopFront:
        s = STHD_TFL;
        break;
    case kAudioChannelLabel_RightTopFront:
        s = STHD_TFR;
        break;
    case kAudioChannelLabel_TopBackLeft:
    case kAudioChannelLabel_LeftTopRear:
        s = STHD_TBL;
        break;
    case kAudioChannelLabel_TopBackRight:
    case kAudioChannelLabel_RightTopRear:
        s = STHD_TBR;
        break;
    case kAudioChannelLabel_LeftTopMiddle:
        s = STHD_TML;
        break;
    case kAudioChannelLabel_RightTopMiddle:
        s = STHD_TMR;
        break;
    case kAudioChannelLabel_LeftWide:
        s = STHD_FWL;
        break;
    case kAudioChannelLabel_RightWide:
        s = STHD_FWR;
        break;
    default:
        return false;
    }
    return true;
}
#endif
} // namespace
extern "C" STHDStatus sthd_default_device_layout(STHDLayout *l, char *description,
                                                 size_t capacity) try {
    if (!l || !description || capacity == 0)
        return STHD_INVALID_ARGUMENT;
    *l = STHDLayout{};
    std::snprintf(description, capacity, "default device unavailable");
#if defined(__APPLE__) && !defined(STHD_DISABLE_NATIVE_DEVICE)
    AudioDeviceID device = 0;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address{kAudioHardwarePropertyDefaultOutputDevice,
                                       kAudioObjectPropertyScopeGlobal,
                                       kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size,
                                   &device) != noErr ||
        device == 0)
        return STHD_DEVICE_UNAVAILABLE;
    address = {kAudioDevicePropertyPreferredChannelLayout, kAudioObjectPropertyScopeOutput,
               kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &size) != noErr)
        return STHD_UNKNOWN_LAYOUT;
    if (size < offsetof(AudioChannelLayout, mChannelDescriptions))
        return STHD_UNKNOWN_LAYOUT;
    std::vector<uint8_t> buffer(size);
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, buffer.data()) != noErr)
        return STHD_DEVICE_UNAVAILABLE;
    auto *layout = reinterpret_cast<AudioChannelLayout *>(buffer.data());
    if (layout->mChannelLayoutTag != kAudioChannelLayoutTag_UseChannelDescriptions) {
        const bool bitmap = layout->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap;
        const AudioFormatPropertyID property = bitmap ? kAudioFormatProperty_ChannelLayoutForBitmap
                                                      : kAudioFormatProperty_ChannelLayoutForTag;
        UInt32 value = bitmap ? layout->mChannelBitmap : layout->mChannelLayoutTag;
        UInt32 expanded_size = 0;
        if (AudioFormatGetPropertyInfo(property, sizeof(value), &value, &expanded_size) != noErr)
            return STHD_UNKNOWN_LAYOUT;
        std::vector<uint8_t> expanded(expanded_size);
        if (AudioFormatGetProperty(property, sizeof(value), &value, &expanded_size,
                                   expanded.data()) != noErr)
            return STHD_UNKNOWN_LAYOUT;
        buffer = std::move(expanded);
        layout = reinterpret_cast<AudioChannelLayout *>(buffer.data());
    }
    unsigned channels = layout->mNumberChannelDescriptions;
    std::snprintf(description, capacity, "CoreAudio default output, %u labelled channels",
                  channels);
    if (channels < 2 || channels > 16 ||
        buffer.size() < offsetof(AudioChannelLayout, mChannelDescriptions) +
                            channels * sizeof(AudioChannelDescription))
        return STHD_UNKNOWN_LAYOUT;
    for (unsigned i = 0; i < channels; ++i)
        if (!apple_label(layout->mChannelDescriptions[i].mChannelLabel, l->speakers[i]))
            return STHD_UNKNOWN_LAYOUT;
    // Preferred layout must agree with the actual output stream configuration.
    address = {kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput,
               kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &size) != noErr)
        return STHD_DEVICE_UNAVAILABLE;
    std::vector<uint8_t> streams(size);
    if (size < offsetof(AudioBufferList, mBuffers) ||
        AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, streams.data()) != noErr)
        return STHD_DEVICE_UNAVAILABLE;
    auto *list = reinterpret_cast<AudioBufferList *>(streams.data());
    if (streams.size() <
        offsetof(AudioBufferList, mBuffers) + list->mNumberBuffers * sizeof(AudioBuffer))
        return STHD_UNKNOWN_LAYOUT;
    unsigned actual = 0;
    for (unsigned i = 0; i < list->mNumberBuffers; ++i)
        actual += list->mBuffers[i].mNumberChannels;
    if (actual != channels)
        return STHD_UNKNOWN_LAYOUT;
    l->channels = channels;
    return checked(*l);
#elif defined(_WIN32) && !defined(STHD_DISABLE_NATIVE_DEVICE)
    HRESULT init = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(init) && init != RPC_E_CHANGED_MODE)
        return STHD_DEVICE_UNAVAILABLE;
    struct Cleanup {
        IMMDeviceEnumerator *enumerator = nullptr;
        IMMDevice *device = nullptr;
        IAudioClient *client = nullptr;
        WAVEFORMATEX *format = nullptr;
        bool uninit;
        ~Cleanup() {
            if (format)
                CoTaskMemFree(format);
            if (client)
                client->Release();
            if (device)
                device->Release();
            if (enumerator)
                enumerator->Release();
            if (uninit)
                CoUninitialize();
        }
    } c{nullptr, nullptr, nullptr, nullptr, SUCCEEDED(init)};
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                __uuidof(IMMDeviceEnumerator),
                                reinterpret_cast<void **>(&c.enumerator))) ||
        FAILED(c.enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &c.device)) ||
        FAILED(c.device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                  reinterpret_cast<void **>(&c.client))) ||
        FAILED(c.client->GetMixFormat(&c.format)))
        return STHD_DEVICE_UNAVAILABLE;
    unsigned channels = c.format->nChannels;
    std::snprintf(description, capacity, "WASAPI default shared endpoint, %u channels, %lu Hz",
                  channels, static_cast<unsigned long>(c.format->nSamplesPerSec));
    uint32_t mask = 0;
    if (c.format->wFormatTag == WAVE_FORMAT_EXTENSIBLE && c.format->cbSize >= 22)
        mask = reinterpret_cast<WAVEFORMATEXTENSIBLE *>(c.format)->dwChannelMask;
    else if (channels == 2)
        mask = SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT;
    if (!mask || channels < 2 || channels > 16)
        return STHD_UNKNOWN_LAYOUT;
    const uint32_t bits[] = {
        SPEAKER_FRONT_LEFT,      SPEAKER_FRONT_RIGHT,   SPEAKER_FRONT_CENTER,
        SPEAKER_LOW_FREQUENCY,   SPEAKER_BACK_LEFT,     SPEAKER_BACK_RIGHT,
        SPEAKER_SIDE_LEFT,       SPEAKER_SIDE_RIGHT,    SPEAKER_TOP_FRONT_LEFT,
        SPEAKER_TOP_FRONT_RIGHT, SPEAKER_TOP_BACK_LEFT, SPEAKER_TOP_BACK_RIGHT};
    for (unsigned bit = 0; bit < 32; ++bit)
        if (mask & (1U << bit)) {
            bool found = false;
            for (unsigned s = 0; s < 12; ++s)
                if (bits[s] == (1U << bit)) {
                    if (l->channels >= 16)
                        return STHD_UNKNOWN_LAYOUT;
                    l->speakers[l->channels++] = STHDSpeaker(s);
                    found = true;
                    break;
                }
            if (!found)
                return STHD_UNKNOWN_LAYOUT;
        }
    if (l->channels != channels)
        return STHD_UNKNOWN_LAYOUT;
    return checked(*l);
#elif defined(STHD_HAVE_PIPEWIRE) && !defined(STHD_DISABLE_NATIVE_DEVICE)
    STHDAudioCapabilities capabilities{};
    auto status = sthd_audio::pipewire_capabilities(capabilities);
    std::snprintf(description, capacity, "PipeWire sink %s, %u labelled/profile channels",
                  capabilities.endpoint, capabilities.pcm_channels);
    if (status != STHD_OK)
        return status;
    if (!capabilities.pcm_layout_valid)
        return STHD_UNKNOWN_LAYOUT;
    *l = capabilities.pcm_layout;
    return STHD_OK;
#elif defined(STHD_HAVE_ALSA) && !defined(STHD_DISABLE_NATIVE_DEVICE)
    snd_pcm_t *pcm = nullptr;
    if (snd_pcm_open(&pcm, "default", SND_PCM_STREAM_PLAYBACK, SND_PCM_NONBLOCK) < 0)
        return STHD_DEVICE_UNAVAILABLE;
    struct Cleanup {
        snd_pcm_t *p;
        ~Cleanup() { snd_pcm_close(p); }
    } cleanup{pcm};
    snd_pcm_chmap_t *map = snd_pcm_get_chmap(pcm);
    if (!map) {
        std::snprintf(description, capacity,
                      "ALSA default PCM does not report an active channel map; provide --layout");
        return STHD_UNKNOWN_LAYOUT;
    }
    struct MapCleanup {
        snd_pcm_chmap_t *p;
        ~MapCleanup() { free(p); }
    } map_cleanup{map};
    std::snprintf(description, capacity, "ALSA default PCM, %u labelled channels", map->channels);
    if (map->channels < 2 || map->channels > 16)
        return STHD_UNKNOWN_LAYOUT;
    for (unsigned i = 0; i < map->channels; ++i) {
        switch (map->pos[i] & SND_CHMAP_POSITION_MASK) {
        case SND_CHMAP_FL:
            l->speakers[i] = STHD_FL;
            break;
        case SND_CHMAP_FR:
            l->speakers[i] = STHD_FR;
            break;
        case SND_CHMAP_FC:
            l->speakers[i] = STHD_FC;
            break;
        case SND_CHMAP_LFE:
            l->speakers[i] = STHD_LFE;
            break;
        case SND_CHMAP_RL:
            l->speakers[i] = STHD_BL;
            break;
        case SND_CHMAP_RR:
            l->speakers[i] = STHD_BR;
            break;
        case SND_CHMAP_SL:
            l->speakers[i] = STHD_SL;
            break;
        case SND_CHMAP_SR:
            l->speakers[i] = STHD_SR;
            break;
        case SND_CHMAP_TFL:
            l->speakers[i] = STHD_TFL;
            break;
        case SND_CHMAP_TFR:
            l->speakers[i] = STHD_TFR;
            break;
        case SND_CHMAP_TRL:
            l->speakers[i] = STHD_TBL;
            break;
        case SND_CHMAP_TRR:
            l->speakers[i] = STHD_TBR;
            break;
        case SND_CHMAP_TSL:
            l->speakers[i] = STHD_TML;
            break;
        case SND_CHMAP_TSR:
            l->speakers[i] = STHD_TMR;
            break;
        case SND_CHMAP_FLW:
            l->speakers[i] = STHD_FWL;
            break;
        case SND_CHMAP_FRW:
            l->speakers[i] = STHD_FWR;
            break;
        default:
            return STHD_UNKNOWN_LAYOUT;
        }
    }
    l->channels = map->channels;
    return checked(*l);
#else
    std::snprintf(description, capacity,
                  "native device discovery unavailable in this build; provide --layout");
    return STHD_DEVICE_UNAVAILABLE;
#endif
} catch (const std::bad_alloc &) {
    return STHD_OUT_OF_MEMORY;
} catch (...) {
    return STHD_DEVICE_UNAVAILABLE;
}
