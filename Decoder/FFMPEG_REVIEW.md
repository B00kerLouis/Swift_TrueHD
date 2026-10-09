# Independent Decoder integration with FFmpeg

Date: 2026-10-06. Scope: the Decoder and its independent FFmpeg adapter.
The 48 kHz FBA profile and existing rendering/playback architecture are
preserved. Moving OAMD and PCM checksum reporting are implemented. Encoder
implementation and existing user changes are retained; licensing is split
between the Encoder research license and Decoder LGPL.

## Completed work

| Area | Implementation and result |
|---|---|
| Independent codec | `Integrations/FFmpeg/libtruehdddec.c` registers `libtruehdd` with `AV_CODEC_ID_TRUEHD`, preserving `mlpdec.c` |
| Build registration | External-library discovery, codec/Makefile registration, version, Changelog, documentation, FATE definitions and a repeatable installer |
| Xcode compatibility | Existing `libtruehdec -> truehdec` graph, macOS 11+, arm64/x86_64; adapter compiled only inside FFmpeg |
| Random-access checksums | Reset skips the unavailable preceding interval checksum; current restart CRC and subsequent interval checks remain enabled |
| Major-sync parsing | Actual header length follows extension flags/counts; validates channel arrangements, modifiers, presentation/format flags and element counts |
| PCM delivery | Right-aligned 24-bit PCM becomes full-scale S32; `ff_get_buffer` allocates output; exact core layouts and unspecified element layouts |
| Timing and lifetime | Packet PTS, actual sample duration, final trimming, flush/preroll, corrupt-packet recovery, error codes and frame/metadata ownership |
| Metadata | Copied frame dictionary carries presentation, DRC validity/codes, OAMD validity/coordinates and sample-aligned motion; no new FFmpeg public ABI |
| Redistributable tests | Four original synthetic streams and one timed OAMD variant; 16 FATE cases without an Encoder runtime |
| Error-path coverage | libFuzzer mutator repairs outer integrity checks and exercises AU sequences, transactional state and PCM bounds |
| Licensing and distribution | LGPL Decoder/adapter and separate downstream Encoder research license; file headers, installation and CI products updated |

## Inherited metadata during random access

`Sources/DecoderFramework/Decoder.cpp` accepts valid middle-of-stream
major-sync AUs after reset. Continuous decoding and restarting at each major
sync produce identical PCM.

Major sync does not necessarily repeat OAMD or DRC updates. Neither can be
inferred from channel counts or default unity values. Element PCM remains
available with `positions_valid=0` until OAMD arrives.
`sthd_decoder_drc_valid`, added in Decoder 1.2.0, returns per-presentation
received-code flags while preserving the existing Frame layout and C ABI v3.
Failures do not change validity. FFmpeg metadata marks missing values
unavailable and omits unknown coordinate/gain-code tags. Position views and
rendering still require valid coordinates.

Relevant implementation: `restart`, `major_sync` and `sthd_decoder_drc_valid`
in `Sources/DecoderFramework/Decoder.cpp`. Public contracts are in
`include/TrueHDDecoder.h` and [PLAY_API.md](PLAY_API.md).

## Earlier local validation of the 1.2 adapter

- Xcode 26.3: truehdec Release and libtruehdec Debug builds pass;
  both products retain arm64/x86_64. Xcode project and Encoder target settings
  are unchanged.
- Apple Clang 17 CMake Release: CTest 5/5, including compressed 7.1 and
  12/14/16-element fixtures, corrupt input, header combinations, transactional
  failures, random access and nine layouts.
- FFmpeg revision `2da55bf59a68801a8157ab141a487196ce3416a8`: the minimal
  configuration enables independent `libtruehdd`; all 15 PCM FATE results
  match Swift pre-entropy reference hashes.
- Configured FFmpeg `make fate`: 317/317 pass. The upstream 1,301-byte MOV
  boundary sample was added without changing its test/reference. This is not
  a full configuration of every FFmpeg codec.
- Fifteen API cases pass: sample-aligned S32/PCM, two independent instances,
  arbitrary initial PTS, flush, final sample count/duration, OAMD delay and
  recovery, DRC validity, metadata disabled, corrupt packets, missing
  presentations, preroll and retained frame lifetime after close.
- Decoder core and adapter C source with ASan/UBSan: the same 15 API cases
  match packed pre-entropy PCM sample for sample; Decoder sanitizer CTest 5/5.
- LLVM 23 libFuzzer: 47,521 runs, coverage counter 1,767, no ASan/UBSan
  errors. This bounded smoke check does not exhaust all malformed states.
- Adapter C source and API tests compile with `-Wall -Wextra -Werror`.
- Installer succeeds on a clean pinned upstream checkout and on repeat
  invocation. Differing existing adapter files are not overwritten;
  `mlpdec.c` is unchanged.

Evidence is retained in ignored `Build/FFmpegAdapter/`: `fate-all-final.log`,
`adapter-checks.log`, `api-sanitized.log`, `fuzz-final.log`, final Xcode build
logs and CMake `Testing/Temporary/LastTest.log`. Synthetic stream and PCM
reference origins and SHA/MD5 are in
[fixtures/references.json](../Integrations/FFmpeg/fixtures/references.json).

## Submission boundaries

No FFmpeg PR was created or submitted. The registration patch targets a
pinned upstream revision. Submission requires updating to the then-current
master, checking context and addressing upstream review. macOS/Linux adapter
CI and Linux fuzz smoke are part of the workflow; the original local review
did not run the new Windows/Linux CI jobs.

The sample-rate profile remains 48 kHz. Rendering and native playback consume
sample-aligned motion. Programme-level records are in
[VALIDATION.md](VALIDATION.md); integration and reproduction instructions
are in [Integrations/FFmpeg](../Integrations/FFmpeg/README.md).

Primary rules and interfaces:
[development guidelines](https://ffmpeg.org/developer.html),
[FATE](https://ffmpeg.org/fate.html),
[FFCodec](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/codec_internal.h).

### Decoder 1.3 follow-up

The adapter delivers sample-aligned OAMD motion through a bounded float32
LE/base64 dictionary and marks quantized coordinate snapshots. PCM checksum
mismatches produce warnings and corrupt-frame flags; `AV_EF_EXPLODE` selects
transactional rejection. The minimum pkg-config version at this stage is
1.3.0, with C ABI v3 frames unchanged. The timed fixture, 16 API cases and
16 PCM FATE cases pass. Complete element PCM from the supplied external MLP
matches the direct CLI MD5. Xcode and Encoder source compatibility is retained.

The complete supplied-file adapter API check also passes: 130,000 AUs,
5,200,000 samples and 1,049 major syncs, covering PCM, PTS, trim, motion
metadata, random access, retained frame lifetime and errors. Its 96 mismatch
AVFrame corrupt flags agree with C API evidence. Strict FFmpeg
`-xerror -err_detect explode` correctly stops at AU 372.

### Decoder 1.4 official matrix follow-up

DME primitive/extended matrices, shifts, dither, bypass, delta interpolation,
quantization, FIR/IIR state and related guard/DRC/ramp fields are supported.
The minimum pkg-config version at this stage is 1.4.0; C ABI v3 Frame remains
unchanged. FFmpeg copies incoming target metadata without marking unknown
startup/seek ramp origins valid. Fields, differences and full-programme
validation are in [MATRIX_COMPATIBILITY.md](MATRIX_COMPATIBILITY.md).
There are no modifications to or integration into mlpdec.

### Decoder 1.4.1 termination follow-up

The Windows DEE 5.2.1 programme uses the `D234 E000` zero-trim terminator.
The Decoder tracks EOS independently of trimming, retains the final 40 valid
samples, clears EOS on reset and transactionally rejects following data.
The minimum pkg-config version is 1.4.1. Sixteen fixture API cases, 16 PCM
FATE cases and the official programme's PCM/API comparison pass; mlpdec
remains unchanged.
