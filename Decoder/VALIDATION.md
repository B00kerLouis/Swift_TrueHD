# Decoder validation record - 2026-10-02

## Result

Both supplied MXFs completed full-programme encode/decode. The comparison
target is the original Encoder's pre-entropy element PCM, including
compatibility transport, per-layer inverse matrices, output shift and
ch_assign. All 2/6/8/16 layers match byte for byte. Reference PCM was generated
independently from the unmodified Swift Encoder snapshot at the start of this
work, not derived through the new Decoder. Reference generation exists only
as an Encoder-side test tool in ignored `Build/DecoderValidation`, outside
all Decoder targets.

| Input / profile | Input samples | AUs | Output bytes | Four-layer PCM comparison |
|---|---:|---:|---:|---|
| QWER_TBH_IAB / 16 elements | 11,036,000 | 275,900 | 242,719,220 | All 2/6/8/16 match |
| Dolby_NaturesFury_IMF_IAB / 16 elements | 5,200,000 | 130,000 | 103,030,720 | All 2/6/8/16 match |
| Dolby_NaturesFury_IMF_IAB / 12 elements | 5,200,000 | 130,000 | 87,137,970 | All 2/6/8/12 match |
| Dolby_NaturesFury_IMF_IAB / 14 elements | 5,200,000 | 130,000 | 95,433,300 | All 2/6/8/14 match |

These streams are 48 kHz with 20-bit coded elements restored to 24-bit PCM
through output shift. TBH lasts 229.916667 seconds; NaturesFury lasts
108.333333 seconds.

NaturesFury-16 layers 2/6/8 also match the independent FFmpeg TrueHD Decoder
byte for byte. FFmpeg is a test oracle, not a Decoder product dependency.

## Layout and safety tests

All four complete streams render every AU into nine layouts: 2.0, 5.1, 7.1,
5.1.2, 5.1.4, 7.1.2, 7.1.4, 7.1.6 and 9.1.6. Checks cover finite values,
channel counts, per-channel RMS, peaks and clipping. At unity gain, these four
programmes have zero clipped samples in every tested layout.

- A C compiler includes the public C header directly and creates/destroys
  Decoder instances.
- Independent impulses for every spatial element validate layout energy,
  LFE isolation, anchor routing and height folding.
- A front-wide coordinate impulse routes exactly to FWL; reversed physical
  channel order reverses output correctly.
- Ground 5.1 folds matching side/rear PCM into surround. Tests cover Side and
  Back platform labels, including the common WASAPI 0x3f mask.
- Plain 7.1 without an immersive layer does not invent height audio.
- Synthetic 7.1 input includes channel impulses, distinct sine frequencies
  and fixed-seed full-scale random PCM. Its 12,345 samples produce 309 AUs
  with 15 samples removed from the last AU. Complete decoded 7.1 PCM exactly
  matches the source WAVE.
- Every single-bit flip in the first AU of each programme is rejected. Other
  cases include 2,000 fixed-seed malformed inputs, missing major sync,
  insufficient output capacity, duplicate speaker labels and invalid frame
  sizes.
- Failed AUs change neither Decoder state nor output frames; subsequent
  valid AUs still decode.
- ASan/UBSan covers unit tests, synthetic streams, complete NaturesFury-12
  four-layer reference comparison and nine-layout rendering, without reports.
- SIGINT cleans newly created CLI outputs and sidecars. Existing output files
  remain unchanged; raw presentation extraction matches byte for byte.

Actual CLI outputs include `NaturesFury-7.1.wav`, `NaturesFury-9.1.6.wav`,
`TBH-9.1.6.wav`, `NaturesFury-5.1-back.wav` and `synthetic-decoded.wav`.
ffprobe confirms 16 channels, 48 kHz and 24 bits for both 9.1.6 WAVEs, with
5,200,000 and 11,036,000 samples respectively. The 5.1-back output has six
channels, a back-channel mask and the complete sample count. Automatic RF64
switching above 4 GB is implemented; these outputs did not reach that limit,
so this branch was not tested with a real file above 4 GB.

Front Wide: the current Encoder's fixed basis has no front-wide elements.
Consequently, wide channels in both 16-element programmes are zero in 24-bit
9.1.6 output. Tests verify routing for real front-wide coordinates; they do
not claim to recover IAB positions already discarded by the Encoder. The
independent nine-layout renderer was not compared to Dolby's renderer.

## Initial build results

| Platform / tool | Validation | Not performed in this initial check |
|---|---|---|
| macOS / Xcode 26.3 | truehdec Release, libtruehdec Debug and original Encoder all Release pass; both Decoder products include arm64/x86_64 | Physical multichannel speaker playback |
| macOS / CMake + Apple Clang | Framework, CLI and C/C++ tests build; CTest and ASan/UBSan pass | None listed |
| Windows x86_64 / MinGW GCC 16.2.0 | Framework, Unicode CLI and tests cross-compile; CLI has no libgcc/libstdc++ DLL imports | Native Windows execution, WASAPI devices, native MSVC build |
| Linux x86_64-musl / Zig 0.16.0 Clang | CMake framework/CLI/test ELF cross-builds pass; ALSA adapter branch also compiles | Native Linux execution, native GCC build, ALSA devices |

macOS `otool -L` lists only C++/system runtimes and CoreAudio/AudioToolbox,
without Swift, Encoder or third-party Decoder frameworks. Local device
inspection runs on macOS. At this stage the default device reported two
Unknown channel labels; auto correctly rejected layout inference, while an
explicit layout worked. Later preferred-stereo-pair support is recorded below.

New project code builds without warnings. Initial Linux cross-validation
failed because system ar/ranlib did not understand ELF; selecting Zig
ar/ranlib fixed the build. Cross-tool header nullability/ALSA extension
warnings are outside the Decoder sources; final project build records have
no related source warnings.

SHA-256 for the original 29 sources, tests and README/VALIDATION files matches
the initial snapshot. Six existing uncommitted files were retained without
overwrite. The Xcode project only added configuration objects, group/product
references and two targets (47 added lines, no deleted lines); existing
schemes remained unchanged.

## Artifacts and reproduction

Local evidence is under `Build/DecoderValidation/`:

- `*-validation.json`: four-layer PCM comparison flags and nine-layout
  statistics; `referencePresentations=15` indicates all four layers compared.
- `NaturesFury-ffmpeg-validation.json`: independent FFmpeg comparison;
  `referencePresentations=7` indicates layers 2/6/8.
- `*-oracle.*.pcm`: pre-encoding references; `*.mlp`: actual native output.
- `*-sanitized.json`, `cli-validation.json`, `*-build.log` and
  `xcode-targets.json`: safety, file handling and build evidence.
- `hashes.json`: source, stream and PCM SHA-256; `original-files.json`:
  initial file hashes.

Repeat validation for existing elementary streams:

```sh
Build/DecoderValidation/CMake/decoder_tests --stream \
  Build/DecoderValidation/TBH-16.mlp Build/DecoderValidation/TBH-oracle
Build/DecoderValidation/CMake/decoder_tests --stream \
  Build/DecoderValidation/NaturesFury-16.mlp Build/DecoderValidation/NaturesFury-oracle
Build/DecoderValidation/CMake/truehdec -i Build/DecoderValidation/TBH-16.mlp --verify-only
```

Generate independent Decoder references:

```sh
ffmpeg -v error -downmix stereo -i INPUT.mlp -c:a pcm_s24le -f s24le REF.2.pcm
ffmpeg -v error -downmix '5.1(side)' -i INPUT.mlp -c:a pcm_s24le -f s24le REF.6.pcm
ffmpeg -v error -i INPUT.mlp -c:a pcm_s24le -f s24le REF.8.pcm
Build/DecoderValidation/CMake/decoder_tests --stream INPUT.mlp REF
```

Stream SHA-256:

| File | SHA-256 |
|---|---|
| TBH-16.mlp | `b5ae3466204cb2438690c98d4e518657ea021251b5e41a17740589a31479b144` |
| NaturesFury-16.mlp | `8083743708c69657a94e073ab2ce7d35cb5f059838cf0eb77364ff25f89fff21` |
| NaturesFury-12.mlp | `23936d4a9606807956ba1d9ecfa33897fff6048f097b3b9fa7a53c9fb3d14165` |
| NaturesFury-14.mlp | `6634534cf9604c3ae8210c69871b64bef6ec926e2cad2d6131b80aa1a33cc800` |

## Native audio / PCM export follow-up

C ABI v2 added bed/object views, native output planning, CoreAudio,
WASAPI/Windows Spatial Audio and PipeWire playback, and a bounded FIFO.
Original Encoder sources retained their initial snapshot.

Local one-second CoreAudio silent playback submitted and consumed 48,000
frames with zero underruns. Real synthetic 7.1 playback consumed exactly
12,345 frames, including correct final trimming, with zero underruns. Policy
tests verify ordinary Windows PCM stays in WASAPI, immersive positional
feeds/native static positions, explicit PCM fallback, Unknown/Discrete
layouts and incompatible-channel rejection. Windows APIs cross-compiled with
MinGW; Linux target compilation used PipeWire 1.0.5 headers.

`Build/DecodePCM/2026-10-02` contains 58 full-programme outputs: WAVE/s24le
PCM for two programmes in nine primary layouts and three Back-label variants,
raw 2/6/8/16 presentations, and NaturesFury 12/14 elements. Twenty-four layout
PCM/WAVE pairs match byte for byte; ten raw presentation extractions match
the original Encoder PCM oracle. `README.md` and `outputs.json` record
absolute paths, formats, sizes and layout sidecars. Large media remains on
the local external drive; source and workflows are committed to GitHub.

`.github/workflows/native-build.yml` builds macOS Encoder/Decoder, Windows
MSVC Decoder and Linux GCC/PipeWire Decoder. The original macOS Encoder
creates a small fixture; all three platforms compare identical PCM. Linux
integration starts isolated PipeWire/WirePlumber servers and labelled virtual
sinks to verify format negotiation, FIFO consumption and drain for all
layouts. Actual Actions results and run URLs are reported separately;
local cross-compilation does not substitute for those results.

Physical multichannel speakers and Windows Spatial Sound/headphone HRTF
still require corresponding playback hardware. Virtual CI sinks validate
native API scheduling and channel negotiation, not physical acoustics.


## Encoded streaming player / DLL / SO follow-up

C ABI v3 adds a real-time encoded-input player with arbitrary chunk framing, exact consumed-byte progress, one retained pending PCM frame on backpressure, retryable finish, cancellation and copied last-frame/statistics APIs. CLI `play` and binary stdin use the same player. Windows/Linux build shared DLL/SO and export C ABI only.

Local CoreAudio complete-program tests used gain zero to verify actual scheduling without audible output:

| Stream | Accepted bytes | Decoded AUs | Decoded / submitted / consumed frames | Zero-timeout retries | Underruns |
|---|---:|---:|---:|---:|---:|
| NaturesFury-16 | 103,030,720 | 130,000 | 5,200,000 / 5,200,000 / 5,200,000 | 64,649 | 0 |
| TBH-16 | 242,719,220 | 275,900 | 11,036,000 / 11,036,000 / 11,036,000 | 136,651 | 0 |

Fragment sizes include 1, 3, 7, 65,536, 5 and 8,191 bytes, so AU boundaries are not supplied by the test caller. Zero-timeout retries close without duplicate decode/enqueue; final counters match exact programme sample count. The synthetic fixture verifies 12,345-frame final trim, last frame timeline, idempotent finish, input refusal after finish, and active/cross-thread cancellation. Partial headers/payloads, invalid lengths, empty streams and ABI options size are tested before opening a device. Local native player tests also pass ASan/UBSan.

Local MinGW build produces `truehdec.dll` and confirms all `sthd_player_*` exported symbols. Linux target builds an ELF shared `libtruehdec.so` with versioned SONAME. Actions package DLL/import library or SO and header, link/run C ABI tests against the shared products, and play encoded fragments through each labelled PipeWire sink. Physical Windows Spatial Sound playback remains a hardware validation boundary.


## Auto mapping regression — 2026-10-03

Auto now reads endpoint metadata for all supported configurations, preserving physical slot order. Shared validation covers all nine primary families, back-label variants, reversed maps and absent/duplicate/incompatible positions. CoreAudio SDK tag/bitmap expansion tests verify both MPEG 7.1 and bitmap/WAVE 7.1 rear/side ordering. Windows uses the mix mask or the endpoint PhysicalSpeakers property and never converts an absent mask to stereo by channel count. PipeWire integration adds reversed 7.1/7.1.4/9.1.6 and rejects 16 AUX positions.

The actual local device reported Unknown channel labels but an explicit preferred stereo-channel pair L=1/R=2 for its two active slots. That OS declaration establishes this device's route; it is not a default layout for other terminals. The user's exact QWER_TBH_A.mlp playback path was tested with `--play --layout auto`, default gain, and no manual layout: 275,900 AUs, 11,036,000 decoded and consumed frames, underruns=0, complete 229.916667-second programme. Multi-channel terminal maps are independently read from their OS metadata and are not inferred from this local test.

## Independent FFmpeg adapter — 2026-10-06

Decoder 1.2.0 adds the independent `libtruehdd` FFmpeg C wrapper and corrects
reset/random-access checksums, inherited metadata validity and major-sync
extension/profile parsing. Frame layout and C ABI v3 remain unchanged;
`sthd_decoder_drc_valid` adds an explicit validity query. The existing Xcode
graph and Encoder implementation are preserved.

Local results: Xcode truehdec Release/framework Debug, CMake CTest 5/5,
15 independent PCM FATE hashes, 15 API lifecycle/metadata/error cases (also with
adapter/core ASan/UBSan), configured FFmpeg `make fate` 317/317, and 47,521
structured fuzz runs. Original synthetic streams and reference hashes are
checked in under `Integrations/FFmpeg/fixtures`; no Encoder runtime is required
for those decoder tests. See [FFMPEG_REVIEW.md](FFMPEG_REVIEW.md) for scope,
commands, evidence paths and platform boundaries.

## Moving OAMD / supplied July stream - 2026-10-06

Input is the external-drive file
`Dolby_NaturesFury/Rederer/Dolby_NaturesFury_TrueHD.mlp`, SHA-256
`600833445efbeb5a7d545ef7429396aab47cc5b6cdb0fbfa53bf49c4c920c175`,
71,797,242 bytes. It differs from the re-encoded NaturesFury fixture above.
Complete decoding yields 130,000 AUs, 5,200,000 samples and 16 elements,
lasting 108.333333 seconds.

The previous moving-OAMD rejection at AU 76 was replaced with sample/block
offset, target and ramp parsing, sample-aligned coordinates and persistent
cross-AU state. No guessed offset/motion compatibility branch is used.
At zero-based AU 372, the fourth presentation exposes a PCM checksum mismatch:
expected `63`, actual `e4`. The complete file has 96 mismatches; remaining
transport CRC/parity/authentication checks pass. The initial historical
Encoder source inherits transmitted matrices on ordinary AUs, while
`updateLosslessChecks` uses each AU's target matrix; that path can produce
these inconsistencies. Encoder sources, input and PCM were not modified to
force an eight-bit checksum match. Default mode reports mismatches and
reconstructs PCM from the transmitted matrices; strict mode rejects AU 372.

The official DRP 4.2 GStreamer Decoder served as an external local oracle,
using its public properties:
`dlbtruehdparse align-major-sync=false enable-metadata=true`,
`dlbtruehddec presentation=16 out-ch-config=raw max-errors=0 drc-mode=disabled`.
It outputs the complete 332,800,000-byte S32LE programme. Default parser
major-sync alignment caused incorrect feeding; that failed output was not
used as a reference. The DRP CLI renderer also exported a complete 7.1 WAVE.

DRP raw output retained approximately -8 dB gain and an S32 `-256` offset,
so it was not directly byte-identical. Gain was calibrated exclusively from
the first 100,000 samples of object channel 12, which bypasses inverse
matrices, to `0.398106068321705031`. Adding back the offset, dividing by gain
and quantizing to the encoded 20-bit grid (S32 step 4096) gives zero
differences across all 83,200,000 channel samples. Calibration and logs are
under `Build/MovingOAMD/`. This cross-check validates decoded element PCM;
it does not certify bit-identical rendering. Raw reference SHA-256 is
`1307a41ba63dc4fe7ff65d5394a5f085e6689f4bd6f34038c16d9bf96d4a173d`.

| Check | Result |
|---|---|
| Xcode truehdec Release / libtruehdec Debug | Pass, arm64 + x86_64; final build has no project source warnings |
| CMake CTest | 7/7, including timed OAMD, strict/report checksum modes and transactional retries |
| ASan/UBSan | 7/7 plus complete stereo decode of the supplied file, no reports |
| CoreAudio playback, gain 0 dB | 5,200,000 decoded/consumed frames; zero underruns |
| Stereo WAVE | Peak 0.569202; zero clipped samples |
| Raw 16-element PCM | Peak 0.470465; zero clipped samples; MD5 `5d1b822afc7e2fb3203ab9e70c5720ff` |
| Independent FFmpeg adapter, complete elements | Same MD5; metadata export does not affect PCM |
| FFmpeg adapter API / PCM FATE | 16 fixture API cases and 16 FATE cases; complete 130,000-AU API/motion/frame-error verification |
| Windows MinGW / Linux Zig x86_64 | DLL/import library, SO/SONAME 1, CLI and tests cross-build; not native device execution |

`timed-16.mlp` retains synthetic-16 audio substreams and adds timed OAMD
authenticated by the current Encoder. It does not replace audio data.
Coverage includes offsets 18, 7 and 33, a future AU offset 73, ramps
0/64/73/512/1536, interrupted ramps, new metadata after seek, LFE preservation
and FIFO coordinate/PCM alignment. Generation/oracle code remains in ignored
Build directories, outside Decoder products. Element sidecars stream each
update instead of treating the final snapshot as programme-wide fixed
coordinates. Encoder source hashes remain equal to the initial values.

## Official matrix compatibility - 2026-10-06

Decoder 1.4 fully decodes native DME 6.5.4 NaturesFury 12/14/16-element
streams: each has 130,010 AUs, 5,200,384 samples and zero strict PCM checksum
mismatches. All four DME-16 layers, totaling 166,412,288 channel samples,
match FFmpeg/DRP references sample for sample, without gain fitting or PCM
correction. Fresh output from the current Swift Encoder still passes strict
checks; Encoder/CLI hashes retain their initial values.

CMake and ASan/UBSan pass 8/8, including independent matrix syntax vectors;
complete DME-16 strict sanitizer decoding passes. Xcode framework Debug/CLI
Release, Windows MinGW and Linux Zig cross-builds pass. CoreAudio gain-zero
full-programme playback accepts 89,259,600 bytes and 130,010 AUs; decoded,
submitted and consumed counts all equal 5,200,384, with zero underruns.
Metadata startup preroll does not prevent ordinary core-channel playback.
Six spatial layouts correctly report 1,560 samples without a complete
coordinate trace; subsequent spatial rendering is finite and unclipped.

Fields and statistics are in
[MATRIX_COMPATIBILITY.md](MATRIX_COMPATIBILITY.md); evidence is under
`Build/OfficialDecoder/`. Results cover only the documented 48 kHz FBA
profile, not every TrueHD format or bit-identical Dolby rendering. The final
interval has no subsequent PCM checksum field; its transport CRC/parity
and metadata authentication pass.

The fuzz smoke check completes 188,110 runs in 31 seconds without ASan/UBSan
reports. FFmpeg's 16 fixture API cases and 16 PCM FATE cases pass, along with
complete DME-16 PCM/PTS/trim/target/motion metadata, random-access, retained
frame lifetime and error-path validation. The older July file still reports
expected 63 / actual e4 at AU 372 in strict mode; compatibility fixes do not
bypass PCM validation. Final structured evidence is in local
`Build/OfficialDecoder/validation.json`.

## Windows DEE under Wine - 2026-10-07

The supplied DEE 5.2.1 and bundled Wine 10.13 encode the same IAB into a
16-element stream: 89,258,394 bytes, 130,000 AUs and 5,200,000 samples.
Windows and native official encoders both use 7-16 extended matrix rows,
variable precision/shifts, dither/bypass, delta interpolation and FIR/IIR.
These are richer choices than the Swift fixed subset. The two official
preprocessing outputs are not PCM-identical.

Decoder 1.4.1 fixes zero-trim EOS, preserving all 40 final-AU samples while
recognizing explicit termination. All 4,472 strict PCM checksum checks pass.
Four layers totaling 166,400,000 channel samples match this stream's
FFmpeg/DRP references exactly, without numerical fitting or correction.
CoreAudio gain-zero decoded/submitted/consumed counts all equal 5,200,000,
with zero underruns. CTest 8/8, ASan/UBSan 8/8, full strict sanitizer decoding,
Xcode dual-architecture builds and Windows/Linux cross-builds pass. Swift
Encoder, Encoder CLI and Xcode project files are unchanged.

After supplying standard MinGW runtime DLLs, the Windows DLL/CLI completes
strict decoding under the same Wine: 130,000 AUs, 5,200,000 samples and zero
checksum mismatches. Eight tests, complete four-layer PCM reference comparison,
random-access PCM equivalence and nine-layout rendering pass. This does not
test physical Windows audio devices. See local
`Build/WineDEEChecksum/README.md` and permanent syntax comparisons in
MATRIX_COMPATIBILITY.md.

### Three-source release check

Decoder 1.4.1 completed full strict decoding of the following fresh NaturesFury
streams. This records tested inputs rather than universal MLP/TrueHD support.

| Encoding source | Elements | AUs | Samples | PCM checksum mismatches |
|---|---:|---:|---:|---:|
| Current Swift Encoder | 16 | 130,000 | 5,200,000 | 0 |
| Native DME / DEE 6.5.4 | 16 | 130,010 | 5,200,384 | 0 |
| Windows DEE 5.2.1 through Wine | 16 | 130,000 | 5,200,000 | 0 |

Native DME 12/14-element streams also passed full strict checks. The official
16-element streams matched their own FFmpeg 2/6/8-channel and DRP element PCM
references sample for sample. The current Encoder's earlier interval checks
also passed; encoding-stage spatial reduction remains outside compression
losslessness. The older July file still fails strict PCM checks at AU 372;
it is not treated as a clean stream by this release.
