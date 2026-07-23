# Swift TrueHD

Swift 6 TrueHD encoding framework and CLI for macOS. Surround 7.1 and Atmos
encoding, spatial rendering, Huffman/FIR/LPC optimization, metadata protection,
and bitstream assembly are implemented in Swift. The project neither invokes
nor ships an external Atmos encoder.

## Automatic format selection

- A plain 8-channel PCM WAVE is encoded as lossless 7.1 TrueHD using 2-, 6-,
  and 8-channel cumulative substreams. Input channel order is
  `L R C LFE Lb Rb Ls Rs`.
- A DAMF, MXF IAB, or ADM WAVE master is encoded as native 12-, 14-, or
  16-element TrueHD Atmos.

The caller does not select a transport profile, entropy mode, element depth, restart
period, peak-rate declaration, or encoder implementation. These are internal
compliance decisions. Atmos starts at 20-bit elements and automatically retries
19, 18, then 17 bits only if an encoded access unit would exceed the 18 Mbps
transport ceiling. The validated restart interval is selected internally.

The internal Atmos spatial coder reduces source ADM tracks to the requested
12, 14, or 16 transport elements.
Object-to-cluster assignments remain stable transport tracks. At each 1,536-sample
OAMD metadata interval, moving-cluster positions and 7.1 matrix render targets are
updated so moving objects follow their current positions without discontinuously
switching PCM element tracks. The selected element depth and fixed whole-program
headroom keep the four cumulative presentations within the 18 Mbps TrueHD
transport ceiling. This reduction is
intentionally not described as track-for-track lossless; after spatial coding,
the transported elements and their 7.1 compatibility-matrix relation are
lossless.

The 2-, 6-, 8-, and 16-channel presentations each carry a self-contained
inverse matrix from the shared transport basis. Higher-channel presentations
do not depend on a lower-channel substream's matrix state. This preserves the
intended stereo fold, paired six-channel surrounds, discrete 7.1 bed, and
independent immersive elements when a decoder switches presentation at run
time.

The native encoder computes the one-byte Evolution primary protection
with HMAC-SHA256 over the complete AU prefix and canonical Evolution frame. The
implementation matches both its unit vector and the supplied Dolby stream's
first-AU protection value. If measured peak-rate rewriting changes an
authenticated AU prefix, the encoder reauthenticates the Evolution frame and
recomputes protected-section parity. The all-native FBA fourth substream and its
16-channel presentation pass complete Dolby Reference Player playback.

## Entropy Coding and Performance

The native encoders use the three fixed MLP Huffman codebooks with stateful 15-bit
offset search. Raw and codebook candidates are compared using their actual VLC,
LSB, offset-change, and parameter-signalling costs. The encoder also evaluates
raw PCM, fixed order-1...4 FIR predictors, and data-derived order-1...8
Levinson-Durbin LPC filters using the residuals produced by the quantized
coefficients that are written to the stream.

Native Atmos coding treats a restart interval as the independent optimization
and parallelism boundary. Fixed FIR2, fixed FIR4, and LPC8 interval candidates are
encoded independently and the smallest complete interval is committed. Input
and spatial rendering are processed in batches of up to eight restart
intervals, while output ordering, metadata timing, and lossless checks remain
deterministic.

On the 93.08-second validation master, the final native Release command
completed in 80.844 seconds and produced 84,089,244 bytes at 7.227 Mbps average,
9.408 Mbps P99, and 13.402 Mbps peak. DRP's strict decoder consumed every one of
the Auto, 2-, 6-, 8-, and 16-channel presentations to EOS with no reported
issue.

The Atmos headroom pass caches its exact unscaled Int64 element PCM in the
system temporary directory so the many-track ADM/DAMF source is not rendered
twice. The cache requires `spatialClusterCount * 8` bytes per input sample
(about 572 MB for the 93.08-second 16-element validation master) and is removed
on success, cancellation, or failure.

## Build

The Xcode project is the single source of truth for the Framework, CLI, and
tests. Build the macOS framework and CLI together with the shared Scheme:

```sh
xcodebuild \
  -project Swift_TrueHD.xcodeproj \
  -scheme all \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath Build/XcodeAllTargets \
  build
```

The framework and CLI are written to
`Build/Products/Release/libtruehda.framework` and
`Build/Products/Release/turehda`. Both contain arm64 and x86_64 slices. The
framework binary is a static archive: Xcode links its object code directly into
`turehda`, so the CLI can be copied and run without shipping
`libtruehda.framework` beside it.

The standalone-link requirement can be checked with:

```sh
! otool -L Build/Products/Release/turehda | grep -q libtruehda
Build/Products/Release/turehda --help
```

Run the Xcode-managed test target with:

```sh
xcodebuild \
  -project Swift_TrueHD.xcodeproj \
  -scheme SwiftTrueHDTests \
  -configuration Debug \
  -destination 'platform=macOS' \
  test
```

## Source Layout

The Framework source is grouped by responsibility so new format support can be
added without growing one flat directory:

- `Swift_TrueHD/Core`: public configuration/types, timing, bit writing, and MLP checksums.
- `Swift_TrueHD/Metadata`: ADM parsing, Atmos metadata, and encode manifests.
- `Swift_TrueHD/Encoding`: TrueHD and Atmos bitstream/spatial encoders.
- `Swift_TrueHD/IO`: WAVE input and high-resolution timing output.
- `Swift_TrueHD/API`: Objective-C bridge classes.
- `CLI`: the `turehda` executable entry point.

The Xcode synchronized source groups include these directories recursively.
The shared `all` Scheme builds the `libtruehda` framework target first and then
the `turehda` CLI target; `SwiftTrueHDTests` is a separate Xcode-managed test target.

## CLI

```sh
Build/Products/Release/turehda \
  -i /path/to/master-damf \
  -o atmos-master-14.mlp \
  --spatial-clusters 14
```

The complete public CLI is:

- `-i, --input PATH`
- `-o, --output PATH.mlp`
- `--spatial-clusters 12|14|16` (default: `16`)
- `--ffoa HH:MM:SS:FF` (optional; default: `00:00:00:00`)
- `--frame-rate 23.976|24|25|29.97df|29.97|30` (optional)
- `--drc-profile film_standard|film_light|music_standard|music_light|speech`
  (optional; default: `film_light`)

Without `--frame-rate`, the output timecode rate follows the input DBMD/DAMF/IAB
rate. `--ffoa` describes the output timeline and does not silently trim the
input master. Removed or unknown options are rejected instead of being ignored.
An existing output path is never overwritten implicitly.

## Dynamic range control profiles

`--drc-profile` selects genuine TrueHD DRC gain metadata; it is not an encode
label and it never modifies the lossless PCM. A decoder may apply, scale, or
disable this metadata. The native analyzer uses a 48 kHz B-weighted peak
detector (LFE excluded), attack/release smoothing, dialogue-normalization
translation, signed 9-bit gain updates, and TrueHD interpolation time code 7.

The curve breakpoints below are stated at the published -31 dB dialogue
reference. They are translated to each presentation's dialogue-normalization
value before analysis.

| Profile | Low-level boost | Unity region | High-level behavior |
|---|---|---|---|
| `film_standard` | up to +6 dB; 2:1 from -43 to -31 dB | -31 to -26 dB | 2:1 early cut, then 20:1 limiting |
| `film_light` | up to +6 dB; 2:1 from -53 to -41 dB | -41 to -26 dB | gentler cinema cut; default |
| `music_standard` | up to +12 dB; 2:1 from -55 to -31 dB | -31 to -26 dB | 2:1 early cut, then 20:1 limiting |
| `music_light` | up to +12 dB; 2:1 from -65 to -41 dB | -41 to -21 dB | no early-cut branch; 2:1 cut |
| `speech` | up to +15 dB; 5:1 from -50 to -31 dB | -31 to -26 dB | faster adaptive updates and strong speech limiting |

Film and music profiles emit a regular update every 128 access units. Speech
uses the same baseline cadence and adds transient updates when its faster target
trajectory changes materially. Each cumulative 2/6/8/16-channel presentation
carries its own gain trajectory.

Every successful encode automatically writes two companion files beside the
elementary stream:

- `OUTPUT.mlp.mll`: a machine-readable job manifest containing input timing,
  encoder options, presentation structure, output path, and execution times.
- `OUTPUT.mlp.log`: a human-readable encode/verification record containing
  timing, selected clusters, byte count, duration, average rate, and status.

Raw encoder output must use the `.mlp` extension. When muxing to Matroska, the
audio track must use codec ID `A_TRUEHD`; the raw MLP payload is not modified.

## Swift API

```swift
import libtruehda

let configuration = TrueHDEncoderConfiguration(spatialClusterCount: 14)
// Optional overrides; defaults are 00:00:00:00 and the input frame rate.
configuration.firstFrameOfAction = "01:00:00:00"
configuration.frameRate = .fps24
configuration.drcProfile = .filmLight

let result = try await TrueHDEncoder().encode(
    inputURL: inputURL,
    outputURL: outputURL,
    configuration: configuration
)
print(result.outputByteCount)
print(result.outputFrameRate?.displayName ?? "not indicated")
print(result.manifestURL.path, result.logURL.path)
```

## Objective-C API

```objective-c
#import <libtruehda/libtruehda-Swift.h>

STTrueHDEncoderConfiguration *configuration =
    [[STTrueHDEncoderConfiguration alloc] initWithSpatialClusterCount:14
                                                   firstFrameOfAction:@"00:00:00:00"
                                                               frameRate:STTrueHDOutputFrameRateInput
                                                              drcProfile:STTrueHDDRCProfileFilmLight];

STTrueHDEncoder *encoder = [STTrueHDEncoder new];
[encoder encodeWithInputURL:inputURL
                  outputURL:outputURL
              configuration:configuration
            progressHandler:nil
           completionHandler:^(STTrueHDResult *result, NSError *error) {
    // Handle result or error.
}];
```

The exact generated selector is available in the framework's
`libtruehda-Swift.h` header.

## Validation

The regression workflow checks:

- Swift 6 Release compilation and 47 XCTest cases covering checksums, bit
  packing, Huffman offset inheritance, FIR/LPC residuals, ADM metadata,
  HMAC reauthentication, restart seed evolution, DRC curves and gain packing,
  headroom-cache equivalence, source timing, and native DAMF/IAB readers;
- exact synthetic 7.1 PCM round-trip MD5 through FFmpeg's independent TrueHD
  decoder, including the 2/6/8 cumulative-substream topology;
- exact full-program PCM MD5 equality between the pre-entropy Swift raw stream
  and the optimized Huffman/FIR/LPC stream;
- all five DRC profiles through the independent and DRP decoders, including
  exact source PCM with DRC disabled and profile-dependent playback gain with
  DRC enabled;
- complete AU parsing, AU count, average/P95/P99/peak rate measurements, and
  SHA-256 comparison against the supplied official MLP;
- byte-for-byte equality between cached and non-cached Atmos rendering paths;
- complete strict-decoder EOS for Auto/2/6/8/16 across all five DRC profiles,
  plus Dolby Reference Player GUI switching and playback of the pure-Swift
  2/6/8/16-channel presentations.

See [VALIDATION.md](VALIDATION.md) for the current official-stream comparison,
decoder results, rate distribution, and artifact hashes.

This project has been tested for playback with Dolby Reference Player 4.2.0.
This project is not Dolby-certified. No license to any Dolby patents,
trademarks, format rights, or certification rights is granted by this project.
Product distribution or commercial use may require rights or licenses
independent of the source code license.

## License

Copyright © 2026 B00kerLouis. Licensed under the GNU Affero General Public
License v3.0 only (`AGPL-3.0-only`). See [LICENSE](LICENSE). Relevant upstream
attributions are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
