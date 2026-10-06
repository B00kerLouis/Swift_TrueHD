# Bitstream analysis and decoder implementation

Complete-file evidence covers the project's output and the tested DME 6.5.4
48 kHz FBA syntax. The encoding pipeline below describes this project's
Encoder. Official-stream differences and Decoder limits are documented in
[MATRIX_COMPATIBILITY.md](MATRIX_COMPATIBILITY.md). Unimplemented syntax is
rejected explicitly.

## Encoding pipeline

1. `NativeMasterReader.open` identifies MXF IAB, DAMF, ADM or PCM WAVE input.
   `TrueHDEncoder` selects plain 7.1 or Atmos from the ADM metadata.
2. Plain 7.1 input uses `L R C LFE Lb Rb Ls Rs` order and three cumulative
   substreams carrying channels 0..1, 2..5 and 6..7.
3. For Atmos, `AtmosSpatialCoder.prepareElementCache` prepares IAB decoding,
   spatial anchor reduction and headroom/limiting. The stable basis consists
   of eight ground/LFE elements and 4/6/8 height elements. Complete object
   tracks are not written individually into TrueHD.
4. Each 40-sample AU transforms elements into a shared transport basis. The
   first two values include center and surround folding. Subsequent substreams
   use their own inverse matrices to produce 5.1, 7.1 and immersive elements.
   The fourth-layer matrix executes row by row; it cannot reuse transport PCM
   that has already passed through the 7.1 inverse matrix.
5. The first block of each restart AU contains eight raw samples that seed the
   FIR filter, followed by a 32-sample block. Subsequent AUs normally contain
   40 samples. Fixed-order FIR and LPC analysis both produce quantized FIR
   coefficients. Actual coding cost selects among three fixed MLP Huffman
   codebooks and signed 15-bit offsets. Offsets and filter parameters persist
   between AUs.
6. OAMD carries fixed spatial positions; the Encoder's PCM panning already
   represents original object motion. The Evolution HMAC covers the complete
   AU prefix and the canonical frame with authentication fields cleared.
   The transport rewriter updates input timing and peak rate, then renews
   authentication.

## AU container

| Position | Length | Meaning |
|---|---:|---|
| Bytes 0..1 | 16-bit BE | High four bits: header parity; low 12 bits: total AU length in 16-bit words |
| Bytes 2..3 | 16-bit BE | `input_timing`: buffered input scheduling, not fixed PCM playback PTS |
| Byte 4 | Optional 28 or 32 bytes | `F8 72 6F BA` major sync, 48 kHz FBA; three plain layers or four Atmos layers |
| Major sync + 16 | 4 bits | Cumulative substream count; high nibble of AU byte 20 |
| Final two major-sync bytes | LE16 | MLP checksum16 |
| After major sync | 2 or 4 bytes per layer | Substream directory; low 12 bits: cumulative end position in words; bit 15: DRC extra word |
| After directory | Variable | Cumulative audio substreams, each with parity and checksum8 |
| After final audio substream | Optional, variable | Protected Evolution/OAMD wrapper |

An AU is at most 8190 bytes and normally represents 40 samples at 48 kHz.
The final frame may be shortened. The DRC extra word contains a signed
nine-bit gain code, a three-bit interpolation-time code (0..7), and four
reserved bits. The Decoder returns the gain code and preserves PCM without
applying DRC by default.

## Substreams and prediction

Each block starts with parameter-present and restart-present flags. Restart
types are `0x31EA` (stereo), `0x31EB` (six/eight channels) and `0x31EC`
(immersive). A restart includes channel ranges, the generator seed, the
preceding interval's PCM lossless checksum, `ch_assign` and restart CRC.

Huffman reconstruction is:

```text
lsb_bits = huff_lsbs - quantizer_step
signed_offset = inherited_offset
if codebook != 0: signed_offset -= 7 * 2^lsb_bits
sign_shift = lsb_bits + (codebook != 0 ? 2 - codebook : -1)
if sign_shift >= 0: signed_offset -= 2^sign_shift
residual = wrap32((signed_offset + vlc_table_index * 2^lsb_bits + low_bits) * 2^quantizer_step)
prediction = floor((FIR_dot + IIR_dot) / 2^filter_shift)
sample = quantized(wrap32(residual + prediction))
IIR_history = wrap32(sample - prediction)
```

Coefficient, history and addition widths, negative-value floor operations and
wrap32 are explicit. They do not depend on implementation-defined C++ negative
shifts or out-of-range signed narrowing. Original transport PCM is retained
between layers. Matrices execute row by row on independent copies, followed by
output shift, 24-bit PCM conversion and `ch_assign` ordering. FBA 7.1 speaker
IDs place side channels before back channels, whereas WAVE mask order places
back channels before side channels; output must be reordered.

This Encoder's Atmos `ch_assign` is
`[2,10,7,8,3,0,4,5,9,11,12,13,14,15,6,1]`; 12/14-element profiles select
entries below their element count. DME uses its own permutation, which the
Decoder reads from the stream rather than hard-coding this table. OAMD already
uses the decoded output order for that permutation. The renderer therefore
uses actual `positions[output_index]` values rather than assuming that element
8 always identifies a particular height speaker.

## Integrity and bounded parsing

The Decoder checks AU length and header parity, directory ranges, major-sync
CRC, each layer's restart CRC and parity/checksum8, the preceding restart
interval's PCM checksum, matching final trim across all four layers,
Evolution wrapper length/parity, OAMD element lengths and syntax, and EMDF
primary HMAC-SHA256. PCM checksum mismatches are reported by default and
rejected in strict mode. The final incomplete interval has no subsequent
restart PCM checksum, but remains subject to substream CRC/parity and bounded
parsing.

Failures do not commit decode state. State uses fixed arrays; temporary
metadata and HMAC storage is bounded by one AU. Decoding must begin at a
major sync. Explicit reset represents changing streams; no seek/resync scanner
is provided.

## Speaker rendering

| Layout | Channels | Default file/API order |
|---|---:|---|
| 2.0 | 2 | FL FR |
| 5.1 | 6 | FL FR FC LFE SL SR |
| 7.1 | 8 | FL FR FC LFE BL BR SL SR |
| 5.1.2 | 8 | FL FR FC LFE SL SR TML TMR |
| 5.1.4 | 10 | FL FR FC LFE SL SR TFL TFR TBL TBR |
| 7.1.2 | 10 | FL FR FC LFE BL BR SL SR TML TMR |
| 7.1.4 | 12 | FL FR FC LFE BL BR SL SR TFL TFR TBL TBR |
| 7.1.6 | 14 | FL FR FC LFE BL BR SL SR TFL TFR TBL TBR TML TMR |
| 9.1.6 | 16 | FL FR FC LFE BL BR SL SR TFL TFR TBL TBR TML TMR FWL FWR |

Atmos 2.0/5.1/7.1 rendering uses the corresponding compatibility presentations.
Plain 7.1 stereo/5.1 rendering downmixes the full bed; raw presentation
extraction is unchanged. Height layouts use immersive elements and OAMD room
coordinates with cos/sin equal-power interpolation between adjacent left/right
positions, front/side/back planes, and ground/height planes. LFE routes only
to LFE. Ground 5.1 folds matching rear/side channels into surround; .2 height
layouts fold front/back height positions into Top Middle. Bed-only streams
render ground channels and retain zero height PCM.

The 9.1.6 front-wide position lies between the side and front planes. The fixed
Encoder basis has no such anchor: the two supplied outputs have only floating
point zero residuals in wide channels, which become zero in 24-bit WAVE.
Original IAB positions cannot be recovered from discarded information.
Actual front-wide coordinates supplied through the C API route to FWL/FWR;
independent impulse tests cover this path.

## Design decisions

| Candidate | Assessment |
|---|---|
| A: FFmpeg subprocess | Requires a runtime executable and lacks fourth-layer spatial-element access; does not meet the independent Decoder requirement |
| B: Embedded general libavcodec | Reuses mature compatibility presentations but does not cover this project's FBA fourth-layer matrix/OAMD; adds a broad dependency |
| C: Full general TrueHD/MLP decoder | Includes other sample rates, FBB, core topologies and OAMD forms beyond the tested profile |
| D: Existing Swift Encoder or Apple decoder API | Violates the C/C++ and cross-platform boundary; Apple APIs do not expose the required complete elements |
| E: Independent C++ core, C ABI and renderer derived from the current Encoder | Provides available syntax and reproducible PCM references, bounded I/O and independent Xcode/CMake builds; selected |

Rendering candidates included direct channel copying, zero padding, channel
count inference, direction-vector VBAP and a room-coordinate equal-power grid.
The grid was selected to match this Encoder's Cartesian basis, preserve source
anchors and energy, and route by explicit labels. It is not claimed to be
equivalent to a general Dolby renderer.

Primary evidence comes from the local Swift Encoder and actual output. Fixed
MLP fields and basic algorithms were also checked against the
[FFmpeg implementation](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/mlpdec.c).
Speaker names follow the
[Dolby layout guide](https://www.dolby.com/siteassets/technologies/dolby-atmos/atmos-installation-guidelines-121318_r3.1.pdf);
ALSA labels were checked against the
[ALSA source](https://github.com/alsa-project/alsa-lib/blob/master/include/pcm.h).
Decoder 1.4's dither constants have separate FFmpeg attribution in
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). No third-party codec runtime
is required.

### Timed OAMD

For a single metadata block, sample offset modes are 0 (zero), 1
(8/16/18/24), and 2 (five-bit value). The block offset factor is a six-bit
value multiplied by 32 samples. Ramp codes 0/1/2 represent 0/512/1536 samples;
code 3 in the admitted syntax supplies an 11-bit duration. Coordinates ramp
linearly from the specified sample, including across AU boundaries. A new
event continues from the current coordinates at its sample. Position and PCM
reconstruction are separate; motion does not change entropy decoding or the
inverse matrix.

## Decoder 1.4 matrix extensions

Primitive 31EA includes two noise-source columns; 31EB has row dither.
Extended 31EC carries biased coefficient shifts, bypass widths and delta
configuration/value updates. The Decoder normalizes to Q18 and preserves
independent matrix/delta lifetimes, including inactive row state. Parameter
guards, quantizer steps, FIR/IIR state and indexed OAMD ramps are admitted.
See [MATRIX_COMPATIBILITY.md](MATRIX_COMPATIBILITY.md) for measured fields,
scalar semantics and validation scope. The dither lookup constants carry the
FFmpeg attribution in [THIRD_PARTY_NOTICES](../THIRD_PARTY_NOTICES.md).

### Explicit termination without shortening

`D234 E000` is a valid terminator with zero samples to remove. `D234 D234`
is the repeated-word termination form. Decoder 1.4.1 records EOS independently
of trim and preserves all 40 samples for these cases, while still rejecting
malformed suffixes and data following validated termination.
