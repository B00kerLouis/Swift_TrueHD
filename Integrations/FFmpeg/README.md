# Independent FFmpeg Decoder adapter

`libtruehdd` is a separate FFmpeg decoder for `AV_CODEC_ID_TRUEHD`. The C adapter
calls the independent Decoder's public API; it does not modify `mlpdec.c` or add
FFmpeg, Swift or the Encoder to the Decoder products. All files here, including
the original synthetic test media, are under LGPL-2.1-or-later.

The existing Xcode graph remains `decoder_framework -> decoder_cli` and keeps
macOS 11+, arm64/x86_64. Adapter code builds inside FFmpeg, whose internal
`FFCodec` headers are not installed public APIs. They do not become dependencies
of the Xcode framework or CLI. CMake remains the portable library build.

## Build

Use a prefix without whitespace for FFmpeg/pkg-config. For a workspace on a
volume with spaces, a temporary path alias may point to build directories; the
actual sources and products can stay under the project's ignored `Build/`.

```sh
cmake -S . -B Build/FFmpegLibrary -DCMAKE_BUILD_TYPE=Release \
  -DSTHD_NATIVE_DEVICE=OFF -DCMAKE_INSTALL_PREFIX=/path/without/spaces/truehdd
cmake --build Build/FFmpegLibrary --parallel 4
cmake --install Build/FFmpegLibrary

cmake -DFFMPEG_SOURCE=/path/without/spaces/ffmpeg \
  -P Integrations/FFmpeg/install.cmake
```

The installer applies only external-library registration, version/changelog
and documentation changes, then copies the adapter, documentation fragment
and FATE definitions. Reapplying identical files is safe. It refuses to replace
differing installed adapter files. The tested FFmpeg revision is recorded in
`UPSTREAM_REVISION`; other source revisions require registration-context review.

Configure and build in that FFmpeg checkout:

```sh
export PKG_CONFIG_PATH=/path/without/spaces/truehdd/lib/pkgconfig
export LD_LIBRARY_PATH=/path/without/spaces/truehdd/lib
./configure --disable-everything --disable-autodetect --disable-doc \
  --enable-ffmpeg --enable-ffprobe --enable-libtruehdd --pkg-config-flags=--static \
  --enable-decoder=libtruehdd --enable-parser=mlp --enable-demuxer=truehd \
  --enable-muxer=pcm_s24le,pcm_s32le,md5,framecrc \
  --enable-encoder=pcm_s24le,pcm_s32le --enable-protocol=file,pipe,md5 \
  --enable-filter=aresample,aformat,anull --enable-swresample
make -j4
```

`truehdd.pc` carries the C++ runtime and optional native libraries for static
linking. Windows shared-library consumers receive `STHD_SHARED=1`. The tested
adapter requires Decoder 1.4.1 and C ABI v3, including DRC, motion and PCM-checksum queries.
Native playback may still be built and used by the project's normal Xcode/CLI
targets; disabling it here only avoids unnecessary output-device dependencies
for the FFmpeg library build.

## Decode options and frame ownership

```sh
ffmpeg -c:a libtruehdd -presentation 7.1 -i INPUT.mlp \
  -c:a pcm_s24le -f s24le OUTPUT.pcm
ffmpeg -c:a libtruehdd -presentation elements -guess_layout_max 0 -i INPUT.mlp \
  -c:a pcm_s24le -f s24le ELEMENTS.pcm
```

`presentation` accepts `auto`, `stereo`, `5.1`, `7.1`, and `elements`. Auto
selects the fullest encoded presentation. Core output has its actual labelled
layout; immersive elements use `AV_CHANNEL_ORDER_UNSPEC` and the bitstream's
OAMD output order. Their count does not invent a speaker configuration.

The adapter outputs S32 with the encoded signed 24-bit values multiplied by 256.
FFmpeg allocates and owns the frame PCM. Metadata strings and values are copied
into the frame dictionary, so retained frames survive later decoding, flush and
codec destruction. Packet PTS is preserved; duration follows the actual sample
count, including final trim. Flush resets only that decoder instance, skips
non-major preroll, and accepts the next valid major-sync AU.

With `export_metadata=1` (default), dictionary keys are:

| Key | Meaning |
|---|---|
| `truehdd.presentation` | Selected layer index 0..3 |
| `truehdd.drc_gain_valid` | Whether a DRC update has been received |
| `truehdd.drc_gain_code` | Signed code when valid; DRC is not applied |
| `truehdd.positions_valid` | Whether OAMD coordinates are available for elements |
| `truehdd.coordinates` | `normalized_room`, when positions are available |
| `truehdd.xy_denominator`, `truehdd.z_denominator` | 31 and 15 |
| `truehdd.element.N.kind` | `lfe` for element 0, otherwise `object` |
| `truehdd.element.N.x/y/z` | Signed quantized snapshot numerators in output order |
| `truehdd.positions_dynamic` | Movement has occurred in the current stream |
| `truehdd.oamd.sample_offset`, `.ramp_samples` | Incoming target update timing, relative to this AU |
| `truehdd.oamd.targets_xyz_f32le` | Copied base64 float32 LE targets, even during coordinate preroll |
| `truehdd.motion_xyz_f32le` | Base64 sample-major/channel-major xyz float32 LE trace when dynamic |
| `truehdd.motion_valid_samples` | Bit n indicates available coordinates for sample n |
| `truehdd.snapshot_quantized` | Snapshot numerators are rounded; exact ramps are in the trace |

After seek, PCM can precede inherited metadata. Missing DRC/coordinates are
marked unavailable; corresponding value tags are absent until updates arrive.
Coordinates use x left-to-right, y back-to-front and z floor-to-height. These are
copied dictionary entries, not a new FFmpeg public ABI or standard Atmos side
data type. Raw PCM muxers do not preserve them. `export_metadata=0` suppresses
the dictionary without changing PCM.

## Validation

```sh
sh Integrations/FFmpeg/check.sh /path/without/spaces/ffmpeg \
  /path/without/spaces/adapter-checks
```

The check script needs the minimal build above and the installed `truehdd.pc`.
It runs 16 API cases for presentation selection, S32 alignment, PTS/trim, copied
metadata, independent instances, major-sync flush, delayed OAMD, corruption and
recovery, absent presentation errors, disabled metadata and retained frame
ownership. It also runs 16 FATE PCM hashes from Encoder pre-entropy references.
No Encoder executable is needed to build, decode or run those checked-in tests.

`fixtures/references.json` records hashes, sizes and independent reference
origin. Files are original synthetic research audio and each is smaller than
100 KiB. The 7.1 fixture has 5,137 samples; each immersive fixture has 6,417.
All include multiple restart points and a trimmed final AU. Immersive fixtures
also cover coordinates arriving later than a random-access restart.

For decoder fuzzing, use Clang with the libFuzzer runtime (Homebrew LLVM on
macOS; Xcode's Apple Clang installation may omit that runtime):

```sh
cmake -S . -B Build/Fuzz -DSTHD_NATIVE_DEVICE=OFF -DSTHD_BUILD_FUZZER=ON \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++
cmake --build Build/Fuzz --target decoder_fuzz --parallel 4
Build/Fuzz/decoder_fuzz CORPUS -max_total_time=20 -max_len=8190 -timeout=5
```

The harness checks whole AUs and bounded AU sequences, repairs outer integrity
checks for half the mutations, and validates transactional output/DRC state and
PCM bounds under ASan/UBSan. See `Decoder/FFMPEG_REVIEW.md` for local results.
The workflow adds adapter build/API/FATE validation on macOS and Linux; native
Windows portable tests retain the same four checked-in streams.

PCM checksum mismatches log a warning and mark the output AVFrame corrupt; the
transmitted PCM remains available. `-err_detect explode` rejects the AU instead.
Transport CRC/parity and metadata authentication failures always reject input.
Motion dictionary payloads are copied and bounded to 40 samples × 16 channels.
Raw PCM muxers discard motion metadata; hosts must retain the frame dictionary.

Decoder 1.4 supports the tested 48 kHz DME primitive/extended matrix syntax:
variable precision/shift, bypass bits, deterministic dither, coefficient delta
interpolation, quantization and FIR/IIR state. Coordinates may be unavailable
at startup or after seek while a ramp's origin is missing; target metadata is
still delivered. Raw PCM decoding does not depend on positional rendering.
