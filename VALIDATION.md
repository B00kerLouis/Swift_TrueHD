# Validation

Validation uses the supplied `ARI-Water_DAMF` master, a freshly regenerated
reference stream from that same master, Dolby Reference Player (DRP), and
FFmpeg's independent TrueHD parser. Project artifacts are produced by the
native Swift encoder; the installed reference encoder is used only as an
isolated acceptance oracle.

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

- Swift 6 Debug: 40 XCTest cases pass with external fixtures enabled; zero are
  skipped. This includes the full native Evolution audit, the fresh-reference
  HMAC vector, exact restart-seed evolution, matrix round trips, all DRC curves,
  Huffman/FIR/LPC residuals, ADM/DAMF, and MXF IAB input.
- Swift 6 Release: framework and CLI build as universal arm64/x86_64 binaries.
- Backend audit: the executable links only the native project framework and
  Apple system libraries. `Sources` contains no external encoder invocation,
  process launcher, Wine adapter, executable path, or backend branch.
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
