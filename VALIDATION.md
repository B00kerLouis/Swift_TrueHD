# Validation

Validation uses the supplied `ARI-Water_DAMF`, `QWER_TBH_IAB`, and
`Dolby_NaturesFury` masters, a freshly regenerated reference stream, Dolby
Reference Player (DRP), and FFmpeg's independent TrueHD parser. Project
artifacts are produced by the native Swift encoder; the installed reference
encoder is used only as an isolated acceptance oracle.

## Transport timing and Matroska regression

The 2026-07-27 investigation compared every access unit in supplied DEE output
with native output. MLP `input_timing` is a decoder transport schedule, not a
copy of the fixed 40-sample output cadence. For access unit `n`, byte count `B`,
and declared 3 kbps peak-rate code `C`, the validated schedule uses
`ceil(B * 128 / C)` input samples and propagates non-overlap backwards across
future access units. DEE chooses the lowest `C` that keeps the complete schedule
within its 3,600-sample (75 ms at 48 kHz) decoder-buffer window.

The model matched all 111,700 `input_timing` fields in the supplied ARI DEE
stream. That file declares code 3020 (9.060 Mbps) and reaches a 3,533-sample
lead; code 3019 reaches 3,611 and is therefore rejected. The earlier native
candidate declared code 4468 (13.404 Mbps) and emitted the trivial 40-sample
schedule, which did not reproduce DEE's buffered transport pacing.

The corrected full ARI Atmos encode contains 111,700 access units and 4,468,000
samples (93.083333 seconds). It declares code 3883 (11.649 Mbps), reaches 3,597
samples of lead, and code 3882 exceeds the window at 3,601. A complete audit
found zero transport-timing, access-header parity, Evolution length/parity, or
HMAC mismatches. FFmpeg identifies the result as `Dolby TrueHD + Dolby Atmos`;
the raw stream and its `mkvmerge` Matroska copy decode to the same PCM MD5,
`7240b73d5b1e17bd260453a38155e012`.

Container timestamp precision is a separate failure mode. A TrueHD AU lasts
40/48,000 seconds (0.833333 ms), while FFmpeg's default Matroska mux uses a 1 ms
time base. The resulting packet sequence begins `0, 1, 2, 3, 3, 4 ...` ms and
the 93.083333-second stream is rounded to 93.084 seconds. A 24 fps regression
with 48 video packets and 2,400 TrueHD packets passed when muxed with:

```sh
mkvmerge --timestamp-scale 1000 -o output.mkv video-input.mkv output.mlp
```

The resulting 1 microsecond time base preserves strictly increasing audio PTS,
all 48 video frames remain at 24/1, and pre-/post-mux decoded PCM hashes match.
The option must be explicit because `mkvmerge` can inherit a coarse scale from
an existing Matroska video input.

## More-than-eight-channel playback regression

The 2026-07-22 regression candidate was rebuilt from the current Release
sources and encoded from the complete 84-channel `ARI-Water_DAMF` master. It
contains 4,468,000 samples, four TrueHD substreams, and an independent
16-element presentation. The output is 97,416,604 bytes with SHA-256
`bfdc4e09fe0ba1a993fd0c97c073d6b1f1d5481125d179418578de4e93d8dc1f`.

The playback interruption had two related metadata-path causes:

- a known Object OAMD element was preceded by a guessed discard bit, shifting
  the complete Object syntax and causing the object renderer to reject each
  metadata frame;
- DAMF persistent object IDs were treated unconditionally as physical CAF
  channel indexes. The real master has 84 packed CAF channels but IDs through
  101, so the reader must distinguish packed persistent IDs from genuinely
  sparse physical slot arrays.

Dolby Reference Player 4.2.1.17378 validated the corrected stream as follows:

| DRP path | Result |
|---|---|
| Forced 8-channel presentation to 7.1 WAV | EOS, exit 0, 4,468,000 frames |
| Forced 16-channel presentation through OAR to 7.1 WAV | EOS, exit 0, 4,468,000 frames |
| Forced 16-channel presentation through OAR to 7.1.4 on Pro Tools Audio Bridge 16 | Complete real-time playback, exit 0 |

Both decoded WAV files are exactly 93.083333 seconds. A `-90 dB`, 40 ms
silence scan found no interior all-channel dropout in the 16-channel/OAR
render; only the intended final 46.875 ms tail was silent. DRP identified the
stream as FBA Dolby Atmos with four substreams and 16 elements. The complete
native Evolution audit also passed every access-header parity, protected-frame
parity, length, and HMAC check.

## Multi-master encode matrix

The 2026-07-22 acceptance run exercised independent DAMF and IMF IAB sources
with all supported spatial-element counts and different DRC profiles. Every
encode completed from the first source sample through EOS and emitted its
manifest and encode log.

| Source | Input | Elements | DRC profile | Samples / duration | Bytes | SHA-256 |
|---|---|---:|---|---:|---:|---|
| ARI Water | DAMF | 16 | `film_light` | 4,468,000 / 93.083333 s | 97,416,604 | `bfdc4e09fe0ba1a993fd0c97c073d6b1f1d5481125d179418578de4e93d8dc1f` |
| QWER TBH | IMF IAB MXF | 12 | `film_standard` | 11,036,000 / 229.916667 s | 183,229,866 | `a923ca86171d2da4d1bfd350f8cf754e3f466f6750f84fa0c5ea6848eb7cfe82` |
| Dolby Nature's Fury | IMF IAB MXF | 14 | `music_light` | 5,200,000 / 108.333333 s | 88,430,568 | `a69eda50707c9f0057186375a7e7f7a893a244c51f5606af314f1ad784f0192a` |

DRP identified all three results as FBA Dolby Atmos with four substreams and
the requested 12-, 14-, or 16-element independent presentation. For every
stream, forced presentation 8 decoded to 7.1 through EOS, forced presentation
16 plus OAR decoded to 7.1 through EOS, and presentation 16 played to 7.1.4 on
Pro Tools Audio Bridge 16 through EOS. The file decodes produced exactly the
source sample count in both presentation paths.

A `-90 dB`, 40 ms all-channel silence scan compared the presentation-8 and
presentation-16/OAR WAV files. QWER's two intentional interior/tail silence
regions and Nature's Fury's intentional head/tail silence regions matched
between paths after the expected 32-sample OAR latency; no presentation-16-only
dropout was found. The complete native Evolution/OAMD audit passed for both new
IAB encodes, and each supplied IAB master separately passed native frame
indexing and PCM-read validation. The final external-fixture XCTest run passed
47 of 47 tests with zero skips and zero failures.

## Full-program comparison

Both streams contain 111,700 access units and decode to 4,468,000 samples at
48 kHz (93.083333 seconds).

| Stream | Bytes | Average | P99 AU rate | Peak AU rate | Strict DRP presentations |
|---|---:|---:|---:|---:|---|
| Fresh reference, Film Light | 85,007,564 | 7.306 Mbps | 14.381 Mbps | 21.216 Mbps | Auto, 2, 6, 8, 16 |
| Native Swift, Film Light | 84,089,244 | 7.227 Mbps | 9.408 Mbps | 13.402 Mbps | Auto, 2, 6, 8, 16 |

Every strict decode used `max-errors=0`, reached EOS, and reported no lossless,
parity, invalid-data, or metadata error. The native result is 1.080% smaller
than the fresh reference for this master while remaining below the declared
18 Mbps transport ceiling.

The native file contains 901 major-sync/restart access units. All 2,909
Evolution/OAMD frames use HMAC-SHA256 primary protection. The full-file audit
found zero access-header parity, Evolution parity, or HMAC mismatches, and the
fresh reference's authenticated vector was accepted by the same implementation.

## Presentation mapping regression

The reported failure was reproduced before the fix: the six-channel output
could map a transported matrix channel to the wrong speaker, while the eight-
and sixteen-channel outputs retained centre and surround fold components.

The cause was a false inheritance assumption. Primitive matrices belong to the
selected cumulative substream; an eight- or sixteen-channel presentation cannot
depend on the six-channel substream's inverse matrix having executed first. The
encoder now writes a complete inverse from the shared transport basis into each
presentation. The immersive matrix uses dependency-ordered lifting rows, with
separate fixed-point stages where two independently rounded folds must be
reversed.

An ADM channel probe assigns unique bin-centred tones to L, R, C, LFE, both
side surrounds, and both rear surrounds. DRP decoding established:

| Presentation | Probe result |
|---|---|
| 2 channel | Intended centre and surround fold appears on the correct left/right output |
| 6 channel | L/R/C/LFE are discrete; side and rear surround pairs combine on their matching side |
| 8 channel | All eight bed probes are discrete, with no foreign probe above the detection threshold |
| 16 channel | The eight bed probes remain discrete and the spatial element slots remain independent |

The full Film Light candidate was also exercised in the DRP GUI by selecting
2, 6, 8, and 16 channel presentations during playback. Each selection advanced
normally, the expected monitor channels carried signal, and the Alarm panel
remained clear. Finally, every one of the five files in the delivery directory
was opened independently and played with the originally reported 6-channel
presentation selected. All five advanced normally with active monitor channels
and no alarm.

## DRC profile acceptance

The five supported values are `film_standard`, `film_light`,
`music_standard`, `music_light`, and `speech`; omission selects `film_light`.
Every full-program output passed all five strict DRP presentation selections.
DRC-disabled PCM is unchanged by profile selection, while `drc-mode=follow`
produces distinct two-channel PCM for all five profiles:

| Profile | Stream bytes | Stream SHA-256 | Follow-DRC RMS | Follow-DRC peak |
|---|---:|---|---:|---:|
| `film_standard` | 84,089,244 | `cacd2a0003759e4b2e9f3a0f6cb81d0b324637490f30a64efd5612a496c77a58` | 63,370,848 | 697,715,968 |
| `film_light` | 84,089,244 | `b1a2d89f1c588a44169c8c857ed90f6d690255e98d8046071ee5af63a66fbb93` | 63,744,980 | 697,715,968 |
| `music_standard` | 84,089,244 | `a6550caabc16323d92a42d47e18147de0f972d995a0937bea03e47b30202bd82` | 63,824,095 | 697,715,968 |
| `music_light` | 84,089,244 | `65c386165260d184a15e1572fff7859b1762420cc40991b8bcc9cbe5f11e1431` | 79,788,976 | 934,706,560 |
| `speech` | 84,089,296 | `6c92ab3b511a173b441e3b022b803c64e70993b40b1617b7b4b5d3b342dfcb27` | 65,703,952 | 712,073,728 |

The distinct stream and Follow-DRC hashes prove that the option is serialized
and decoder-visible rather than being an encode label. Speech is 52 bytes
larger because its transient-sensitive cadence adds adaptive updates.

## HMAC repair assurance

The HMAC implementation was not replaced or bypassed. A prior decoder failure
was caused by rewriting the measured peak-rate field after metadata
authentication, which changed the authenticated AU prefix. The rewrite path
reauthenticates the affected Evolution frame and recomputes protected-section
parity before committing the AU. A regression test mutates an AU prefix and
verifies both the new HMAC byte and parity.

## Acceptance closure

- Swift 6 Debug: 47 XCTest cases pass with external fixtures enabled; zero are
  skipped. This includes the full native Evolution audit, the fresh-reference
  HMAC vector, exact restart-seed evolution, matrix round trips, all DRC curves,
  Huffman/FIR/LPC residuals, ADM/DAMF, and MXF IAB input.
- Swift 6 Release: the static framework archive and CLI executable build with
  universal arm64/x86_64 slices.
- Backend audit: `libtruehda` is linked into the CLI statically; `otool -L`
  lists no `libtruehda.framework` dependency, and the copied executable starts
  without the framework present. Remaining dynamic dependencies are Apple
  system libraries. `Sources` contains no external encoder invocation, process
  launcher, Wine adapter, executable path, or backend branch.
- Comment audit: source and test comments contain no reference to an external
  encoder product.
- DRP strict decoder: 25 full-program combinations (five profiles multiplied
  by Auto/2/6/8/16) all reach EOS with zero reported issue.
- DRC behavior: five Follow-DRC decodes have distinct hashes and measured
  levels, while DRC-disabled decoding remains lossless.

## Final artifacts

The final delivery directory contains one `.mlp`, one `.mlp.mll` manifest, and
one `.mlp.log` record for each of the five profiles. All use 16 spatial clusters,
24 fps inherited from the input, and FFOA `00:00:00:00`.

- Fresh reference SHA-256:
  `0b02b831c6e2a34342265310ff4005741789bb75a1e11f9cc1d3fe96c5ab029d`
- Supplied reference SHA-256:
  `4c14528bb79372d3a7117eb9a7385353e6c496ee7730dc4683557e75b9b93391`

The native path parallelizes spatial blocks and independently optimizes restart
intervals across fixed FIR2, fixed FIR4, and LPC8 candidates. Complete intervals
are committed in source order so multithreading does not change AU ordering,
metadata timing, or deterministic output.
