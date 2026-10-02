# Project context

This project has a macOS Swift 6 TrueHD encoder and a separate portable C/C++17 decoder. Keep the original encoder sources and existing user changes intact when working on the decoder. Decoder implementation must contain only C/C++; do not add Swift, Objective-C, Objective-C++, Python, a codec subprocess, or a dependency on the encoder to either decoder target.

## Architecture and platforms

- Xcode 26.3 is the tested local toolchain. Existing encoder targets use Swift 6 and macOS 14+ target settings; do not upgrade them as part of decoder work.
- `libtruehda` -> `turehda` is the existing macOS encoder graph.
- `decoder_framework` -> `decoder_cli` is the new independent decoder graph. Products: static `libtruehdd.framework` and standalone `truehdd`; macOS 11+, arm64 and x86_64.
- Decoder sources: `Sources/DecoderFramework` and `Sources/DecoderCLI`. C ABI: `Sources/DecoderFramework/include/TrueHDDecoder.h`.
- Portable CMake builds only the decoder on Windows/Linux (also usable for C/C++ testing on macOS). Require C++17, C, exceptions, standard library; no Swift Package Manager. Windows native discovery uses WASAPI; macOS uses CoreAudio/AudioToolbox; Linux playback uses PipeWire development headers/libraries; legacy ALSA discovery remains optional.
- `DecoderTests` is a separate C/C++ test executable in CMake, outside the existing Swift test group. Do not add decoder sources to the Swift encoder targets.

## State, storage and concurrency

Each decoder owns a fixed bounded stream state and is externally serialized. Separate decoder instances can run concurrently. Decode commits state only on success; public C API does not throw. No SwiftData/database persistence is used in the decoder. Reset represents changing streams; seeking/resynchronization is the host's responsibility.

Stream directly from external paths, one AU (maximum 8190 bytes, 40 samples) at a time. Never stage complete MXF/MLP inputs onto local storage or load whole programmes into memory. CLI writes 24-bit RIFF/RF64 and a channel-order sidecar, refuses overwrite, and cleans newly created incomplete outputs on normal failure or SIGINT/SIGTERM. Abrupt kill/power loss can leave a partial output; no resumable PCM writer is implemented.

Native discovery must use actual labelled topology; channel count alone cannot distinguish 5.1.2 from 7.1 or 5.1.4 from 7.1.2. Unknown/discrete labels require explicit layout. Rendering must honor physical channel order, isolate LFE, retain height PCM, and report PCM clipping rather than silently claim losslessness after rendering.

## Build and validation

macOS authoritative build:

```sh
xcodebuild -project Swift_TrueHD.xcodeproj -scheme decoder_cli -configuration Release -destination 'generic/platform=macOS' -derivedDataPath Build/DecoderDerived build
```

Also build `decoder_framework` Debug when changing the framework. Existing encoder Scheme `all` remains intact.

Portable tests:

```sh
cmake -S . -B Build/DecoderPortable -DCMAKE_BUILD_TYPE=Release
cmake --build Build/DecoderPortable --config Release
ctest --test-dir Build/DecoderPortable -C Release --output-on-failure
Build/DecoderPortable/decoder_tests --stream INPUT.mlp REFERENCE_PREFIX
```

Reference suffixes `.2.pcm`, `.6.pcm`, `.8.pcm`, `.elements.pcm` are optional packed signed 24-bit LE PCM and compare every sample. Stream tests render all nine layouts, validate integrity, test transactional failures and single-bit corruption. Sanitizer builds use ASan/UBSan with native device discovery off. Build/validation artifacts belong under ignored `Build/`, including temporary encoder-side Swift oracles; no non-C/C++ validation logic is part of the decoder products.

## Limits and evidence

Supported syntax is the current encoder's 48 kHz FBA profile, FIR/Huffman, independent 2/6/8 and 12/14/16-element matrices, and fixed-basis OAMD. Unsupported syntax must fail explicitly. DRC codes are exposed but not applied. Native playback is separate from the decoder core: CoreAudio, WASAPI/Windows Spatial Audio, and PipeWire drivers consume a bounded SPSC queue. Ordinary Windows channel PCM uses WASAPI; immersive feeds prefer Spatial Audio objects, with explicit PCM fallback. OS engines handle sample-rate conversion; public decoded PCM remains 48 kHz.

The encoder performs spatial reduction before compression. Round-trip losslessness refers to encoded element PCM, not original IAB source tracks. The room-coordinate equal-power renderer is not validated as bit-identical to Dolby's renderer. Front-wide outputs may be silent because the current fixed basis has no front-wide anchors. CoreAudio silent playback is verified locally. The GitHub workflow builds encoder/decoder on macOS, decoder on Windows/MSVC and Linux/GCC, compares real encoder fixture PCM, and exercises labelled PipeWire virtual sinks. Physical Windows speaker/Spatial Sound rendering still requires a Windows device. See `Decoder/README.md`, `Decoder/BITSTREAM.md`, and `Decoder/VALIDATION.md` for detailed records.

See `Decoder/AUDIO_ARCHITECTURE.md` for C ABI v2 presentation/object views, routing, normalized room coordinate conversion, explicit downmix, queue lifetimes and native error behavior. Preserve unrelated pre-existing encoder edits when staging Git changes.
