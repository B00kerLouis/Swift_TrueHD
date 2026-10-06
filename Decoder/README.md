# TrueHD Decoder

The project provides two independent Xcode targets: `decoder_framework`
(the static `libtruehdd.framework`) and `decoder_cli` (`truehdd`). Decoding,
integrity checks, spatial rendering, device discovery and CLI implementation
use only C/C++. Decoder products do not link the Swift Encoder, FFmpeg or an
external decoder. Existing Encoder sources, tests and schemes are preserved.

The Decoder supports the tested 48 kHz TrueHD FBA elementary-stream profile:
plain 2/6/8 layers and Atmos 2/6/8/12, 14 or 16 layers. MXF is Encoder input;
Decoder input is the resulting `.mlp` elementary stream. MXF/MKV demuxing,
universal TrueHD/MLP syntax coverage and dynamic DRC playback are outside the
implemented scope. Unsupported syntax fails explicitly.

## License and FFmpeg submission review

The Decoder framework, CLI, tests, FFmpeg adapter and documentation use
`LGPL-2.1-or-later`, matching FFmpeg's default license. See the
[LGPL text](../LICENSES/LGPL-2.1-or-later.txt) and component scope in
[LICENSE](../LICENSE). Encoder research, commercial-use, reverse-engineering
and non-Swift port restrictions do not apply to the Decoder.

The independent adapter, build and tests are documented in
[Integrations/FFmpeg](../Integrations/FFmpeg/README.md); implementation and
validation records are in [FFMPEG_REVIEW.md](FFMPEG_REVIEW.md). Select it
explicitly with `-c:a libtruehdd`. It does not modify FFmpeg's `mlpdec`, and
the Xcode framework/CLI retain their existing build graph.

## macOS / Xcode

```sh
xcodebuild -project Swift_TrueHD.xcodeproj -scheme decoder_cli \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath Build/DecoderDerived \
  CONFIGURATION_BUILD_DIR="$PWD/Build/Products/Release" build
```

Open the same `.xcodeproj` and choose `decoder_cli` or `decoder_framework`.
Both targets are independent of `libtruehda` and `turehda`. The CLI depends
only on the Decoder framework and system audio libraries. Xcode 26.3 is the
tested toolchain; the Decoder deployment target is macOS 11.0. Release
products are universal arm64/x86_64 binaries.

```sh
Build/Products/Release/truehdd -i INPUT.mlp -o OUTPUT.wav --layout 7.1.4
Build/Products/Release/truehdd -i INPUT.mlp --verify-only
Build/Products/Release/truehdd -i INPUT.mlp -o ELEMENTS.wav --presentation elements
Build/Products/Release/truehdd --device-info
```

Supported layouts are `2.0`, `5.1`, `7.1`, `5.1.2`, `5.1.4`, `7.1.2`,
`7.1.4`, `7.1.6` and `9.1.6`. The 5.1 family also accepts `5.1(back)`,
`5.1.2(back)` and `5.1.4(back)` for devices labelling their surround pair
BL/BR. Default `--layout auto` reads actual default-device speaker labels;
channel counts do not imply height or speaker positions. Unknown/Discrete
labels require an explicit layout. A two-channel CoreAudio endpoint with an
explicit preferred stereo-channel pair can map L/R automatically, including
reversed physical order. `--speaker-order FL,FR,...` supplies physical order
for the same speaker set as the chosen layout. Optional `--gain-db -6`
provides render headroom; the CLI reports samples clipped during 24-bit
quantization.

`--presentation 2|6|8|elements` extracts the corresponding raw 24-bit PCM
presentation and is mutually exclusive with layout rendering, channel
reordering and gain options. The framework returns DRC gain codes but keeps
lossless PCM without applying DRC by default.

Output is 48 kHz / 24-bit WAVE, switching to RF64 when RIFF length limits are
exceeded. Each output has a `.channels.json` sidecar with exact channel order;
element extraction also records OAMD coordinates. WAVE has no portable Top
Middle / Front Wide mask bits, so layouts containing these speakers use a
zero channel mask and require sidecar-aware playback configuration. They
must not be interpreted as a conventional 16-channel WAVE layout. Device
orders that differ from WAVE mask order also require the sidecar.

Element sidecars stream received OAMD targets, sample times and ramps. On
completion they append the final sample's position snapshot and dynamic flag.
If an entire random-access segment receives no OAMD, `positionsValid=false`
and coordinates and LFE/object labels are omitted. Element PCM and order are
retained; initialized zero arrays are not presented as real coordinates.

`--format s24le` writes headerless packed PCM. `--play` uses the independent
native backend. CoreAudio, WASAPI/Windows Spatial Audio and PipeWire handle
system negotiation and scheduling; ordinary Windows PCM does not enter the
Spatial pipeline. See [native audio architecture](AUDIO_ARCHITECTURE.md).

## Windows / Linux / C++ builds

A C++17 compiler and a C compiler are required. CMake builds only the
Decoder, without compiling the Encoder or changing macOS Xcode architecture.

```sh
cmake -S . -B Build/DecoderPortable -DCMAKE_BUILD_TYPE=Release
cmake --build Build/DecoderPortable --config Release
ctest --test-dir Build/DecoderPortable -C Release --output-on-failure
```

Windows supports MSVC or MinGW. The CLI uses Unicode command lines and paths;
WASAPI shared mix-format channel masks determine device layouts. The MinGW CLI
statically links its own compiler runtime. The shared `truehdd.dll` still
requires its MinGW runtime dependencies alongside the DLL: in the tested
build these are `libstdc++-6.dll`, `libgcc_s_seh-1.dll` and
`libwinpthread-1.dll`. Standard Windows WAVE masks do not represent every Top
Middle / Front Wide position. Hosts must supply an actual `STHDLayout`, or
users must select an explicit CLI layout for such discrete interfaces.

Linux builds PipeWire capability discovery/playback when the
`libpipewire-0.3` development package is found. Active default-sink profiles
and positions determine the layout. Without PipeWire, offline decoding and
rendering remain available; legacy ALSA discovery can provide a compatibility
query path. Unknown/discrete channels require an explicit layout. Real-time
playback requires PipeWire. `-DSTHD_NATIVE_DEVICE=OFF` builds a core without
platform audio API dependencies.

Without CMake, compile the seven `.cpp` files in `Sources/DecoderFramework`
into a library, expose `include/TrueHDDecoder.h`, and link
`Sources/DecoderCLI/main.cpp`. Link CoreAudio/AudioToolbox on macOS and
ole32/uuid on Windows; the MinGW Unicode entry point needs `-municode`.
Linux ALSA discovery requires `STHD_HAVE_ALSA=1` and asound; PipeWire playback
requires `STHD_HAVE_PIPEWIRE=1` and pkg-config flags for `libpipewire-0.3`.
C++ exceptions must be enabled, but never cross the public C ABI.

## C ABI

```c
#include "TrueHDDecoder.h"
STHDDecoder *decoder = sthd_decoder_create();
STHDFrame frame;
STHDLayout output;
float pcm[STHD_MAX_SAMPLES * STHD_MAX_CHANNELS];
if (decoder && sthd_layout_named("7.1.4", &output) == STHD_OK) {
    /* au_bytes is one complete access unit, including its 4-byte header. */
    if (sthd_decode_access_unit(decoder, au_bytes, au_size, &frame) == STHD_OK) {
        if (sthd_render(&frame, &output, 1.0f, pcm, sizeof(pcm) / sizeof(pcm[0])) == STHD_OK) {
            /* Deliver frame.samples * output.channels floats to the device. */
        }
    }
}
sthd_decoder_destroy(decoder);
```

Each Decoder instance owns one stream and is serialized by its caller. The
first AU must contain major sync. Input errors neither commit new decode
state nor modify the output frame. The framework processes one AU of at most
8190 bytes and 40 samples at a time, without loading whole programmes.
Rendered float PCM may exceed +/-1; the host controls quantization, clipping
and volume. The CLI refuses to overwrite existing outputs or sidecars and
removes newly created incomplete outputs on normal failure or SIGINT/SIGTERM.

## Validated scope

Both supplied MXFs completed full-programme encode/decode: TBH has 11,036,000
samples and NaturesFury has 5,200,000. All 2/6/8/16-layer PCM matches the
original Encoder's pre-entropy reference byte for byte. NaturesFury 2/6/8
also matches independent FFmpeg decoding. Validation additionally covers
complete 12/14-element files, nine layouts, impulse/LFE/front-wide/reordering,
final trimming, corrupt streams and ASan/UBSan.

The original Encoder reduces IAB objects to fixed spatial anchors. Lossless
reconstruction applies to encoded elements; original IAB tracks, motion and
information discarded before coding cannot be recovered. This renderer is
an independent equal-power room-coordinate implementation, not validated as
sample-identical to Dolby's renderer. Without front-wide anchors, 9.1.6 Front
Wide outputs can be zero; this does not recover original front-wide objects.
Independent impulses verify routing for actual front-wide positions.

See [bitstream analysis](BITSTREAM.md) and [validation records](VALIDATION.md).

`.github/workflows/native-build.yml` builds the Encoder and Decoder with
Xcode on macOS, and the Decoder with Windows/MSVC and Linux/GCC. A fixture
from the original macOS Encoder provides cross-platform PCM comparisons.
Linux also exercises actual PipeWire virtual-sink playback for all layouts.

## Encoded real-time playback API

C ABI v3 adds `sthd_player_create/feed/finish/cancel/stats/last_frame/destroy` for arbitrary encoded byte chunks. CLI `truehdd play -i INPUT.mlp` and `-i -` use the same session. Windows/Linux CMake products are shared `truehdd.dll` / `libtruehdd.so`, with C-only exported API. See [PLAY_API.md](PLAY_API.md) for lifecycle, backpressure and ownership.

### Moving OAMD and PCM checksums

Decoder 1.3 supports moving coordinates, sample/block offsets and linear ramps
across AUs in the admitted metadata syntax. C ABI v3 frames remain compatible;
motion queries and render APIs provide sample-aligned coordinates. Element
`.channels.json` sidecars stream targets, sample times and ramp durations, and
identify ending coordinates as the final-sample snapshot. PCM checksum
mismatches are reported by default while decoding the transmitted matrix.
`--strict-pcm-checksum` or `--verify-only` makes them transactional failures.
Transport CRC, parity and metadata authentication failures always reject
input. See `PLAY_API.md` and the validation records.

### Official matrix compatibility (Decoder 1.4)

The tested DME 6.5.4 48 kHz FBA matrix syntax includes primitive noise columns,
extended coefficient precision/shifts, dither, bypass LSBs, delta
interpolation, quantization and FIR/IIR state. Complete DME 12/14/16-element
streams pass strict checks. Four-layer PCM from the 16-element file matches
FFmpeg/DRP sample for sample. Field and statistical differences are recorded
in [MATRIX_COMPATIBILITY.md](MATRIX_COMPATIBILITY.md).
Startup/seek ramps with missing origins retain targets and mark coordinates
unavailable until determined. Ordinary core-channel playback remains usable;
positional rendering requires preroll. Encoder sources and the Xcode build
graph remain unchanged.
