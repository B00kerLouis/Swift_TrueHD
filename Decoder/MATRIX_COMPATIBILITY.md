# Matrix compatibility: current Swift stream and DME stream

Validated on 2026-10-06 with the same `Dolby_NaturesFury_IMF_IAB.mxf` input.
The Swift output is freshly built from the current Encoder source; DME is the
locally installed Encoding Engine 6.5.4-dme. Encoder sources remain unchanged.
These are different encoded element programmes, so their PCM is compared to
each encoder's own decode reference, not to each other.

## Measured syntax differences

| Field / operation | Current Swift 16-element stream | DME 16-element stream |
|---|---|---|
| AU count / decoded samples | 130,000 / 5,200,000 | 130,010 / 5,200,384 |
| Primitive rows in 2/6/8 presentations | 0 / 2 / 3 | 2 / 6 / 8 |
| Extended row count | 9 | 7–16, varies with configuration |
| Extended fractional precision | 14 | 3–14 |
| Extended coefficient shift, decoded bias | 0 | -1–6 |
| Extended coefficient updates | 130,000 | 5,275 |
| Extended new configurations | 1,049 | 4,708 |
| Extended AUs with nonzero coefficient delta | 0 | 108,806 |
| Dither / bypass rows observed | none | both present |
| Quantizer step size | 0 | 0–4 |
| Prediction | FIR | FIR and IIR, including explicit IIR state |
| DRC extra-word timing code | fixed 7 | varying valid 3-bit values |
| OAMD ramps | fixed-basis coordinates; explicit durations | moving coordinates; explicit and indexed durations |

Counts are observations for these two files, not universal Encoder defaults.
The field layouts are shared; the previous Decoder had treated the Swift
Encoder's chosen subset as the whole admitted syntax.

## Decoder corrections

Primitive `0x31EA` rows include two extra noise input columns and have no
per-row dither nibble. `0x31EB` rows use only the matrix channels and carry a
per-row dither scale. The omitted columns and extra nibble in the old parser
misaligned the official stereo rows and produced a false destination error.

`0x31EC` configuration carries destination, fractional precision, biased
coefficient shift, bypass width, dither scale and coefficient mask. Coefficients
are normalized to Q18. Matrix configuration, delta configuration and delta
values have independent lifetimes; replacing rows must retain applicable delta
state. Only active rows advance or clear their interpolation state. The Decoder
handles new/inherited coefficients, delta precision, AU-relative interpolation,
deterministic seeded dither and restored bypass bits with checked arithmetic.

Parameter-presence guards, quantizer steps, negative output shifts and FIR/IIR
coefficient/state fields are parsed independently. Quantized prediction and
matrix output preserve the encoded integer operations. DRC is still reported
without being applied; valid timing codes no longer cause rejection. Extended
Huffman widths can reach 31 bits. Table-coded OAMD ramp duration includes 2048
samples; coordinate code 63 follows the specified endpoint clamp.

When a ramp origin is unavailable at startup/seek, its target remains exposed,
but per-sample coordinates stay unavailable until they can be determined.
Core channel PCM and stereo/5.1/7.1 rendering remain usable. Positional/height
rendering requires coordinate validity and host preroll; no fabricated origin
or silently dropped PCM is used. For this DME-16 file, the six spatial test
layouts report 1,560 samples in AUs that do not yet have a complete position
trace. All raw PCM is delivered; eligible rendered samples are finite and have
zero clipping in the local renderer test.

## Verification

- DME-16: complete strict decode, 130,010 AUs, 5,200,384 samples; all four
  presentations check 1,120 preceding restart intervals each, 4,480 total,
  zero PCM checksum mismatches.
- Every decoded 2/6/8 PCM sample matches local FFmpeg's packed 24-bit output.
  Every decoded 16-element sample matches DRP's raw S32LE shifted exactly to
  S24. Dialnorm is -31 and DRC disabled; no gain fitting or sample correction.
  Total comparison: 166,412,288 channel samples. DRP's 16 final padding samples
  are excluded, matching the encoded final trim.
- Additional DME-12 and DME-14 encodes complete strict full-program decoding
  with zero checksum mismatches.
- Independent handcrafted C++ vectors cover noise columns, coefficient shifts,
  dither, multi-bit bypass, quantization, FIR/IIR state, guard masks, delta
  reuse across configuration changes and activation/deactivation of rows.
- Current Swift fixtures continue to pass. The Encoder and its CLI source
  hashes are identical to the start-of-task snapshot.

The last interval has no following restart PCM checksum. Transport CRC/parity,
major/restart CRC and metadata authentication still validate it. Results do not
claim the spatial renderer is bit-identical to Dolby's renderer.

Local evidence is under `Build/OfficialDecoder/`: `exact-pcm.json`,
`pcm-comparison.json`, `dme-syntax.jsonl`, `swift-syntax.jsonl`, build/test logs
and the reference conversion. The complete DME output remains on the external
workspace volume; proprietary software/media are not Decoder dependencies.

## Scope and references

The admitted tested profile remains 48 kHz FBA with cumulative 2/6/8 core
channels and 12/14/16 dynamic elements plus an LFE bed. Other sample rates,
FBB/MLP, other core topologies, ISF/beds and unimplemented OAMD gain/render
properties still fail explicitly. C ABI v3 and the Xcode Encoder graph remain
unchanged; Decoder package version is 1.4.1.

Primary implementation/format cross-checks:
[FFmpeg primitive matrices and filters](https://github.com/FFmpeg/FFmpeg/blob/2da55bf59a68801a8157ab141a487196ce3416a8/libavcodec/mlpdec.c),
[extended matrix field reference](https://github.com/truehdd/truehdd/blob/02d29cd0f8f9163d8951a4a33e55328a2261bf8a/truehd/src/structs/matrix.rs),
[OAMD timing specification, table 23](https://www.etsi.org/deliver/etsi_ts/103400_103499/103420/01.01.01_60/ts_103420v010101p.pdf).
Dither table attribution is in [THIRD_PARTY_NOTICES](../THIRD_PARTY_NOTICES.md).

## Wine DEE cross-check — 2026-10-07

The supplied Windows DEE 5.2.1 was executed using the installed app's Wine 10.13
and existing prefix, with the same IAB input and aligned 16-element/Film-Light/
legacy-authoring/stereo/custom-dialnorm -31 settings. Its MLP core reports 1.10c /
v5.01.01.0003 (MSVC); the native DME core reports the same family (Clang/LLVM).

| Observation | Native DME 6.5.4 | Wine DEE 5.2.1 |
|---|---:|---:|
| AU count | 130,010 | 130,000 |
| Samples | 5,200,384 | 5,200,000 |
| Extended rows | 7–16 | 7–16 |
| Fraction bits / coefficient shift | 3–14 / -1–6 | 3–14 / -1–6 |
| Coefficient updates / configurations | 5,275 / 4,708 | 5,389 / 4,868 |
| Nonzero-delta AUs | 108,806 | 109,569 |
| Dither, bypass, FIR+IIR | present | present |

Both official streams already use adaptive decorrelation and the richer admitted
syntax. Swift's fixed rows/Q14/FIR-only choices are a smaller legal subset.
No evidence identifies Wine itself as the cause; version, preprocessing,
compiler/platform and runtime are not separately controlled by this experiment.
The official decoded programmes are not PCM-identical and immersive slot
indices need not preserve semantic identity across encodes.

The Wine stream terminates with `D234 E000`, preserving all 40 final samples.
Decoder 1.4.1 corrects the old nonzero-trim assumption and tracks EOS separately.
Full strict decode checks 1,118 intervals per presentation (4,472 total), all
passing. All 166,400,000 channel samples match its own FFmpeg/DRP reference
without correction. CoreAudio gain-zero playback consumes 5,200,000 samples,
underruns 0. Evidence is in `Build/WineDEEChecksum/README.md` and `validation.json`.
Encoder source and the Xcode project remain unchanged.
