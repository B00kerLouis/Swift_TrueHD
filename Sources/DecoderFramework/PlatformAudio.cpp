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
[[maybe_unused]] STHDStatus checked(const STHDLayout &layout) {
    return sthd_audio::reported_layout_valid(layout) ? STHD_OK : STHD_UNKNOWN_LAYOUT;
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
#if defined(__APPLE__) && !defined(STHD_DISABLE_NATIVE_DEVICE)
namespace sthd_audio {
bool coreaudio_reported_labels(const uint32_t *labels, uint32_t channels, bool bitmap,
                               STHDLayout &out) {
    if (!labels || channels < 2 || channels > 16)
        return false;
    bool left_direct = false, right_direct = false;
    for (unsigned i = 0; i < channels; ++i) {
        left_direct |= labels[i] == kAudioChannelLabel_LeftSurroundDirect;
        right_direct |= labels[i] == kAudioChannelLabel_RightSurroundDirect;
    }
    STHDLayout map{};
    map.channels = channels;
    for (unsigned i = 0; i < channels; ++i) {
        if (!apple_label(labels[i], map.speakers[i]))
            return false;
        if (bitmap || (left_direct && right_direct)) {
            if (labels[i] == kAudioChannelLabel_LeftSurround)
                map.speakers[i] = STHD_BL;
            if (labels[i] == kAudioChannelLabel_RightSurround)
                map.speakers[i] = STHD_BR;
        }
    }
    if (!reported_layout_valid(map))
        return false;
    out = map;
    return true;
}
} // namespace sthd_audio
#endif
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
    // Read active output slots first. Preferred channel layouts are optional
    // properties, and must never replace the actual stream channel count.
    address = {kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput,
               kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &size) != noErr ||
        size < offsetof(AudioBufferList, mBuffers) || size > 1024 * 1024)
        return STHD_DEVICE_UNAVAILABLE;
    std::vector<uint8_t> streams(size);
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, streams.data()) != noErr)
        return STHD_DEVICE_UNAVAILABLE;
    auto *list = reinterpret_cast<AudioBufferList *>(streams.data());
    if (streams.size() <
        offsetof(AudioBufferList, mBuffers) + list->mNumberBuffers * sizeof(AudioBuffer))
        return STHD_UNKNOWN_LAYOUT;
    unsigned actual = 0;
    for (unsigned i = 0; i < list->mNumberBuffers; ++i)
        actual += list->mBuffers[i].mNumberChannels;
    if (actual < 2 || actual > 16)
        return STHD_UNSUPPORTED_OUTPUT;
    // Tag, bitmap and explicit channel descriptions all come from the device.
    address = {kAudioDevicePropertyPreferredChannelLayout, kAudioObjectPropertyScopeOutput,
               kAudioObjectPropertyElementMain};
    bool complete = false;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, nullptr, &size) == noErr &&
        size >= offsetof(AudioChannelLayout, mChannelDescriptions) && size <= 1024 * 1024) {
        std::vector<uint8_t> buffer(size);
        if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, buffer.data()) ==
            noErr) {
            auto *layout = reinterpret_cast<AudioChannelLayout *>(buffer.data());
            bool expanded = true;
            const bool bitmap_layout =
                layout->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap;
            if (layout->mChannelLayoutTag != kAudioChannelLayoutTag_UseChannelDescriptions) {
                bool bitmap = layout->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap;
                AudioFormatPropertyID property = bitmap
                                                     ? kAudioFormatProperty_ChannelLayoutForBitmap
                                                     : kAudioFormatProperty_ChannelLayoutForTag;
                UInt32 value = bitmap ? layout->mChannelBitmap : layout->mChannelLayoutTag,
                       bytes = 0;
                expanded =
                    AudioFormatGetPropertyInfo(property, sizeof(value), &value, &bytes) == noErr &&
                    bytes >= offsetof(AudioChannelLayout, mChannelDescriptions) &&
                    bytes <= 1024 * 1024;
                if (expanded) {
                    std::vector<uint8_t> out(bytes);
                    expanded = AudioFormatGetProperty(property, sizeof(value), &value, &bytes,
                                                      out.data()) == noErr;
                    if (expanded) {
                        buffer = std::move(out);
                        layout = reinterpret_cast<AudioChannelLayout *>(buffer.data());
                    }
                }
            }
            if (expanded && layout->mNumberChannelDescriptions == actual &&
                buffer.size() >= offsetof(AudioChannelLayout, mChannelDescriptions) +
                                     actual * sizeof(AudioChannelDescription)) {
                std::array<uint32_t, 16> labels{};
                for (unsigned i = 0; i < actual; ++i)
                    labels[i] = layout->mChannelDescriptions[i].mChannelLabel;
                complete =
                    sthd_audio::coreaudio_reported_labels(labels.data(), actual, bitmap_layout, *l);
                if (complete && checked(*l) == STHD_OK) {
                    std::snprintf(description, capacity,
                                  "CoreAudio device %u: %u channels from device layout/labels",
                                  device, actual);
                    return STHD_OK;
                }
            }
        }
    }
    // A stereo preference identifies only two specific slots. It may establish
    // an entire map only for an actual two-slot endpoint, not a multichannel one.
    UInt32 pair[2]{};
    UInt32 pair_size = sizeof(pair);
    address = {kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput,
               kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &pair_size, pair) == noErr &&
        pair_size == sizeof(pair) &&
        sthd_audio::preferred_stereo_layout(actual, pair[0], pair[1], *l)) {
        std::snprintf(description, capacity,
                      "CoreAudio device %u: OS-declared stereo slots L=%u R=%u", device, pair[0],
                      pair[1]);
        return STHD_OK;
    }
    *l = STHDLayout{};
    std::snprintf(description, capacity,
                  "CoreAudio device %u: %u active slots; speaker positions unavailable", device,
                  actual);
    return STHD_UNKNOWN_LAYOUT;
#elif defined(_WIN32) && !defined(STHD_DISABLE_NATIVE_DEVICE)
    HRESULT init = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(init) && init != RPC_E_CHANGED_MODE)
        return STHD_DEVICE_UNAVAILABLE;
    struct Cleanup {
        IPropertyStore *properties = nullptr;
        IMMDeviceEnumerator *enumerator = nullptr;
        IMMDevice *device = nullptr;
        IAudioClient *client = nullptr;
        WAVEFORMATEX *format = nullptr;
        bool uninit;
        ~Cleanup() {
            if (properties)
                properties->Release();
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
    } c;
    c.uninit = SUCCEEDED(init);
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
    if (!mask && SUCCEEDED(c.device->OpenPropertyStore(STGM_READ, &c.properties))) {
        // Exact SDK PKEY_AudioEndpoint_PhysicalSpeakers, not a count heuristic.
        static constexpr PROPERTYKEY key{
            {0x1da5d803, 0xd492, 0x4edd, {0x8c, 0x23, 0xe0, 0xc0, 0xff, 0xee, 0x7f, 0x0e}}, 3};
        PROPVARIANT value{};
        if (SUCCEEDED(c.properties->GetValue(key, &value)) && value.vt == VT_UI4)
            mask = value.ulVal;
        PropVariantClear(&value);
    }
    if (!sthd_audio::wave_mask_layout(channels, mask, *l))
        return STHD_UNKNOWN_LAYOUT;
    std::snprintf(description, capacity,
                  "WASAPI endpoint: %u channels, %lu Hz, device speaker mask 0x%lx", channels,
                  static_cast<unsigned long>(c.format->nSamplesPerSec),
                  static_cast<unsigned long>(mask));
    return STHD_OK;
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
