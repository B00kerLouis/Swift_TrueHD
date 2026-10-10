# Project context

Use `B00kerLouis` as the project's first-party author and new Git author/committer.
Do not add AI co-author trailers. Preserve required third-party license notices.
Keep source comments, software documentation and product text in English.

This project has a macOS Swift 6 TrueHD encoder and a separate portable C/C++17 decoder. Keep the original encoder sources and existing user changes intact when working on the decoder. Decoder implementation must contain only C/C++; do not add Swift, Objective-C, Objective-C++, Python, a codec subprocess, or a dependency on the encoder to either decoder target.

## Architecture and platforms

- Xcode 26.3 is the tested local toolchain. Existing encoder targets use Swift 6 and macOS 14+ target settings; do not upgrade them as part of decoder work.
- `libtruehda` -> `truehda` is the existing macOS encoder graph.
- `libtruehdec` -> `truehdec` is the new independent decoder graph. Products: static `libtruehdec.framework` and standalone `truehdec`; macOS 11+, arm64 and x86_64.
- Decoder sources: `Sources/DecoderFramework` and `Sources/DecoderCLI`. C ABI: `Sources/DecoderFramework/include/TrueHDDecoder.h`.
- Portable CMake builds only the decoder on Windows/Linux (also usable for C/C++ testing on macOS). Require C++17, C, exceptions, standard library; no Swift Package Manager. Windows produces truehdec.dll and an import library; Linux produces libtruehdec.so with SONAME 1. Windows native discovery uses WASAPI; macOS uses CoreAudio/AudioToolbox; Linux playback uses PipeWire development headers/libraries; legacy ALSA discovery remains optional.
- `DecoderTests` is a separate C/C++ test executable in CMake, outside the existing Swift test group. Do not add decoder sources to the Swift encoder targets.

## State, storage and concurrency

Each decoder owns a fixed bounded stream state and is externally serialized. Separate decoder instances can run concurrently. Decode commits state only on success; public C API does not throw. No SwiftData/database persistence is used in the decoder. Reset represents changing streams; seeking/resynchronization is the host's responsibility.

Stream directly from external paths, one AU (maximum 8190 bytes, 40 samples) at a time. Never stage complete MXF/MLP inputs onto local storage or load whole programmes into memory. CLI writes 24-bit RIFF/RF64 and a channel-order sidecar, refuses overwrite, and cleans newly created incomplete outputs on normal failure or SIGINT/SIGTERM. Abrupt kill/power loss can leave a partial output; no resumable PCM writer is implemented.

Native discovery must use actual labelled topology; channel count alone cannot distinguish 5.1.2 from 7.1 or 5.1.4 from 7.1.2. Unknown/discrete labels require explicit layout, except a two-channel CoreAudio endpoint whose explicit preferred stereo-channel pair identifies L/R. Preserve the device physical order; do not infer multichannel positions from counts. Rendering must honor physical channel order, isolate LFE, retain height PCM, and report PCM clipping rather than silently claim losslessness after rendering.

## Build and validation

macOS authoritative build:

```sh
xcodebuild -project Swift_TrueHD.xcodeproj -scheme truehdec -configuration Release -destination 'generic/platform=macOS' -derivedDataPath Build/DecoderDerived build
```

Also build `libtruehdec` Debug when changing the framework. Existing encoder Scheme `all` remains intact.

Portable tests:

```sh
cmake -S . -B Build/DecoderPortable -DCMAKE_BUILD_TYPE=Release
cmake --build Build/DecoderPortable --config Release
ctest --test-dir Build/DecoderPortable -C Release --output-on-failure
Build/DecoderPortable/decoder_tests --stream INPUT.mlp REFERENCE_PREFIX
```

Reference suffixes `.2.pcm`, `.6.pcm`, `.8.pcm`, `.elements.pcm` are optional packed signed 24-bit LE PCM and compare every sample. Stream tests render all nine layouts, validate integrity, test transactional failures and single-bit corruption. Sanitizer builds use ASan/UBSan with native device discovery off. Build/validation artifacts belong under ignored `Build/`, including temporary encoder-side Swift oracles; no non-C/C++ validation logic is part of the decoder products.

## Limits and evidence

Supported syntax is 48 kHz FBA with cumulative 2/6/8 and 12/14/16-element matrices, covering the current Encoder and tested DME 6.5.4 streams. Decoder 1.4 supports primitive noise columns, extended Q18 coefficient shifts/deltas/interpolation, dither/bypass, parameter guards, quantization and FIR/IIR state. OAMD supports the admitted one-block dynamic-element/LFE profile and explicit/indexed ramps; missing ramp origins remain unavailable until determined. See Decoder/MATRIX_COMPATIBILITY.md for scope and evidence. Unsupported syntax must fail explicitly. DRC codes are exposed but not applied. Native playback is separate from the decoder core: CoreAudio, WASAPI/Windows Spatial Audio, and PipeWire drivers consume a bounded SPSC queue. Ordinary Windows channel PCM uses WASAPI; immersive feeds prefer Spatial Audio objects, with explicit PCM fallback. OS engines handle sample-rate conversion; public decoded PCM remains 48 kHz.

The encoder performs spatial reduction before compression. Round-trip losslessness refers to encoded element PCM, not original IAB source tracks. The room-coordinate equal-power renderer is not validated as bit-identical to Dolby's renderer. Front-wide outputs may be silent because the current fixed basis has no front-wide anchors. CoreAudio silent playback is verified locally. The GitHub workflow builds encoder/decoder on macOS, decoder on Windows/MSVC and Linux/GCC, compares real encoder fixture PCM, and exercises labelled PipeWire virtual sinks. Physical Windows speaker/Spatial Sound rendering still requires a Windows device. See `Decoder/README.md`, `Decoder/BITSTREAM.md`, and `Decoder/VALIDATION.md` for detailed records.

See `Decoder/AUDIO_ARCHITECTURE.md` for C ABI v3 presentation/object views, routing, normalized room coordinate conversion, explicit downmix, queue lifetimes and native error behavior. Preserve unrelated pre-existing encoder edits when staging Git changes.

Real-time encoded input is owned by `Sources/DecoderFramework/Player.cpp`: one bounded AU buffer, one pending decoded frame and the existing native FIFO. Respect consumed byte counts on timeout and retain pending frames for retry. `sthd_player_cancel` and `sthd_audio_cancel` signal atomic cancellation; destruction and other producer calls are serialized. Update `Decoder/PLAY_API.md` with any lifecycle/ABI changes.

Decoder 1.4.1 tracks explicit termination independently of sample shortening.
`sthd_decoder_end_of_stream` / `sthd_player_end_of_stream` recognize zero-trim
and repeated-word termination while preserving 40 valid PCM samples. Reset
clears decoder EOS; ordinary host EOF remains separate. Preserve the existing
pending-frame retry and consumed-byte contracts when handling EOS.

Decoder 1.4.2 adds a macOS-only QC GUI under `Sources/DecoderCLI/macos`.
`--play` opens the AppKit player; the `play` subcommand remains headless on all
platforms. Xcode and macOS CMake package `truehdec QC.app`. The GUI is pure C++17
through Objective-C runtime C APIs, isolated from Windows/Linux and the encoder.
Its worker owns AU reading, decoding, replay-based seeking and native output;
export uses a separate worker/decoder. No persistence or programme PCM cache is
introduced. `sthd_audio_write_pcm` submits already-rendered physical-order PCM
with the existing serialized producer and bounded queue contracts. Keep QC
layouts independent of endpoint count and omit 7.1.5. Metering precedes monitor
gain, reports clipping, and retains virtual height feeds on stereo endpoints.

Encoder prediction modes are `auto`, `fir2`, `fir4`, `lpc8` and `none`.
LPC analyzes a bounded restart interval with untapered and Hann-tapered
autocorrelation; windows never modify encoded PCM. All quantized candidate
orders compete on actual residual, Huffman, offset and filter signalling cost.
Ordinary 7.1 input buffers at most one restart interval for analysis. Atmos
reuses prepared intervals and commits the smallest complete FIR2/FIR4/LPC8
candidate. Plain major-sync presentation admission is 0x7C; preserve decoder
support for legacy 0x3C fixtures. `--dialnorm -31` enables neutral DRP PCM
qualification; unspecified dialnorm retains existing stereo/multichannel
defaults. Prediction acceptance uses DRP PCM only, never the portable decoder
or another codec as an oracle. See `Encoder/PREDICTION.md` for public option
and algorithm documentation.

QC responsiveness uses at most 128 fixed-size complete decoder checkpoints,
coarsening their spacing for long streams; no growing programme index or PCM
cache is allowed. `sthd_decoder_clone` preserves FIR/IIR, OAMD pending/origin,
checksum, EOS, strict policy and playback metadata. `sthd_decoder_playback_levels`
reports dialnorm without modifying raw decoded PCM. GUI playback explicitly
applies the selected presentation gain; encoded-PCM mode bypasses it. Height
layouts route positional elements (LFE element 0); layouts without heights use
encoded compatibility PCM (LFE slot 3). Display order is side-before-rear while
raw compatibility extraction retains WAVE order. Keep unavailable ramp origins
explicit, defer scrubbing until mouse release, and preserve physical endpoint
labels/order. Rendered-level comparison allows ±0.5 dB relative to Dolby;
encoded element PCM qualification remains exact. Research evidence stays local.
