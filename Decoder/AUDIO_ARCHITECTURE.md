# Native audio architecture

Decoding, presentations, rendering and native backends are separate components.
`Decoder.cpp` does not inspect devices or alter decoded PCM for a platform.
`Renderer.cpp` handles speaker layouts. `AudioOutput.cpp` provides presentation
views, routing policy and a bounded producer/consumer queue. `NativeAudio.cpp`
and `PipeWireAudio.cpp` manage system APIs, format negotiation and playback.
All implementation remains C/C++17, and the two Xcode Decoder targets are
independent of the Encoder.

## Presentation semantics

`sthd_presentation` returns a view borrowed from the original frame, without
copying a programme or reinterpreting elements as speakers. Ordinary
presentations have 2/6/8 bed channels and no objects. The current Encoder's
immersive profile identifies decoded element 0 as the LFE bed; the remaining
11/13/15 elements are positional feeds with OAMD coordinates.
`STHDAudioObject.id` is the bitstream element index. The Encoder's spatial
reduction prevents complete recovery of original IAB object IDs, tracks and
motion.

A 16-element presentation, a 12-speaker 7.1.4 layout and a 16-speaker 9.1.6
layout are distinct concepts. The renderer produces file layouts; object
views retain source elements and coordinates through the native Spatial Audio
backend.

## Routing and platform differences

| Platform | Ordinary channel PCM | Immersive | Format negotiation |
|---|---|---|---|
| macOS | CoreAudio DefaultOutput AudioUnit | Local renderer to PCM ordered by actual device labels | F32/48 kHz client; AudioUnit converts device format; explicit physical slot map |
| Windows | WASAPI shared event-driven PCM | Prefer positional Spatial Audio objects; use native static positions when resources are insufficient | Float PCM at 48 kHz with system SRC; Spatial requires mono F32/48 kHz support |
| Linux | PipeWire stream | Local renderer to the sink's actual `audio.position` | F32/48 kHz stream; PipeWire converts sink format; implicit remix disabled |

Ordinary TrueHD does not enter the Windows Spatial pipeline by default.
Immersive output first checks `GetMaxDynamicObjectCount` and
`GetNativeStaticObjectTypeMask`. All positional feeds must be retained;
allocating a few objects and dropping remaining signals is not acceptable.
Native static objects lack Top Middle / Front Wide positions, so their channel
count cannot be labelled 7.1.6 or 9.1.6. Static mode renders complete elements
to the actually supported layout.

When Spatial Audio is unavailable, Windows immersive WASAPI fallback requires
explicit `--allow-pcm-fallback`, or explicit `--layout` selection of a local
speaker render. An endpoint with unlabelled discrete channels can retain
physical order and a zero channel mask after the user supplies a layout.
Sixteen output slots alone do not identify 9.1.6.

Windows object coordinates map to listener-relative `(x, z, -y)`. Source
coordinates are normalized room coordinates, with a default scale of one
meter per axis. Hosts can supply actual dimensions through
`room_half_width_m`, `room_half_depth_m` and `room_height_m` in the plan.
Axes and units were checked against
[Microsoft SetPosition documentation](https://learn.microsoft.com/en-us/windows/win32/api/spatialaudioclient/nf-spatialaudioclient-ispatialaudioobject-setposition).
The original fixed-basis implementation had no time-varying coordinates and
explicitly rejected object motion instead of dropping ramp/timing fields.
The current motion API and playback behavior are documented in
[PLAY_API.md](PLAY_API.md).

PipeWire queries registry default metadata, the sink's active format/profile
and positions, distinguishing active channels from total hardware outputs.
A sole sink can be selected unambiguously when default metadata is absent;
multiple sinks are not resolved by choosing the first. Unknown/AUX/Discrete
labels remain unknown. See
[PipeWire raw audio format](https://docs.pipewire.org/structspa__audio__info__raw.html)
and [stream API](https://docs.pipewire.org/group__pw__stream.html).
Legacy ALSA layout discovery remains available without PipeWire; real-time
Linux playback requires PipeWire.

## Plain 7.1 downmix correction

The original plain Encoder's first three layers are cumulative channel
subsets. The first layer does not contain a complete center/side/back downmix.
Decoding still restores every original layer. Plain 7.1 rendering to stereo
or 5.1 instead downmixes the full 7.1 bed explicitly: center and surround use
-3 dB coefficients, 5.1 combines matching side/rear channels, and stereo
excludes LFE. Height layouts do not invent height audio. Ground downmix levels
for plain 7.1 to 5.1.2/5.1.4 match 5.1; adding height outputs does not change
bed gain. Raw `--presentation` extraction is unchanged.

Atmos 2/6/8 compatibility presentations have complete Encoder inverse matrices
and retain their bit-accurate PCM. Downmixing, spatial rendering and output
quantization can create additional peaks. File output reports clipped samples;
playback gain is explicit and does not silently alter lossless decoded PCM.

## Real-time bounds and errors

Each player owns a 16,384-frame SPSC ring with at most 16 channels (1 MiB).
The producer runs decoding and rendering. CoreAudio/PipeWire callbacks only
consume the FIFO, copy data or supply silence; they do not allocate, decode or
perform file I/O. All Windows COM audio objects are created and used on one
MTA render thread. Playback prebuffers 2,048 frames; short programmes start
during drain. Stop ends the native callback/thread before destroying the FIFO.

Write and drain have timeouts. CoreAudio monitors default-device and layout
changes; drain includes converter, device and stream latency plus buffer/safety
offsets. Device changes and negotiation failures report errors instead of
silently selecting another channel layout. `sthd_audio_stats` exposes
submitted/consumed frames and underruns; `sthd_audio_error` provides native
errors. Playback uses each frame's actual sample count, excluding unused
40-sample padding.

## Design decisions

Five approaches were considered: capability-query extensions alone, decoding
inside real-time callbacks, a shared third-party audio wrapper, an external
player/codec dependency, and independent presentations with bounded native
backends. The last approach preserves C/C++ and native API boundaries and
supports C/C++ unit tests, actual CoreAudio playback and isolated PipeWire
sinks. Separate ordinary and Spatial Windows paths preserve their distinct
output semantics.

## Usage

```sh
truehdec -i INPUT.mlp --play --layout 7.1
truehdec -i INPUT.mlp --play                      # actual labels or Spatial capability
truehdec -i INPUT.mlp --play --allow-pcm-fallback # Windows immersive fallback
truehdec -i INPUT.mlp -o OUTPUT.s24le.pcm --layout 7.1.4 --format s24le
truehdec --device-info
```

System volume, DSP, quantization and Spatial/HRTF rendering are outside the
Decoder's byte-exact PCM guarantee. The local renderer is not validated as
sample-identical to Dolby's renderer. The supported 48 kHz profile and current
matrix/OAMD coverage are recorded in [BITSTREAM.md](BITSTREAM.md) and
[MATRIX_COMPATIBILITY.md](MATRIX_COMPATIBILITY.md).

## Auto mapping corrections

Auto reads the endpoint's active physical slot count and OS-declared positions. It never substitutes the developer machine's layout. All three platform readers use the same order-preserving geometry validation. Unsupported/unnamed positions remain unresolved.

CoreAudio reads actual stream configuration before optional preferred layout metadata; expands native tags/bitmaps and explicit labels. WAVE/bitmap Sur+SurDirect and MPEG Sur+RearSur families retain their different native rear/side slot orders. Only a genuinely two-slot endpoint may use an explicit OS preferred stereo-channel pair to complete its map; a stereo monitoring preference cannot label a multichannel interface. Slot-reversed pairs remain reversed.

Windows reads GetMixFormat.dwChannelMask, then PKEY_AudioEndpoint_PhysicalSpeakers if the mask is unavailable. Both masks must describe the actual active channel count. It does not invent FL/FR from an unlabelled count of two. Spatial static positions/object budget remain separate from physical PCM slots. See [Microsoft endpoint speaker properties](https://learn.microsoft.com/en-us/windows/win32/coreaudio/pkey-audioendpoint-physicalspeakers).

PipeWire reads current format, active sink profile/position properties, and default sink metadata; AUX/UNPOSITIONED channels do not become speaker positions. Integration tests include nine layout families, 5.1 back-label, reversed 7.1/7.1.4/9.1.6 physical order and 16 unpositioned AUX slots. These virtual fixtures validate metadata handling; they are not treated as a user's hardware configuration.
