# Spatial aggregate object modes

The encoder exposes `--object-mode dynamic|channelbase` and the equivalent
Swift/Objective-C configuration property `objectMode`. The output budget is
12, 14, or 16 total transport elements: one isolated LFE and 11, 13, or 15
non-LFE spatial elements. `--object-mode` is optional and defaults to `dynamic`,
as does the Swift/Objective-C configuration. This is spatial aggregation, not independent
transport of the original source objects. No high-count object output mode
is implemented or planned.

`channelbase` retains the established fixed-position rendering basis. It
still writes static OAMD, which the immersive decoder requires. Source motion
is represented by PCM gains across the fixed basis.

`dynamic` aggregates non-LFE sources into moving centroids. LFE remains
isolated. Finite-size objects pass through bounded 512-sample spatial
preprocessing with transient-protected decorrelation and eleven internal
7.1.4 mix buses. These buses feed the reducer and are not extra output objects.

The reducer analyzes 24 critical bands over overlapping 1536-sample
intervals. It allocates centroids by loudness and speaker coverage, preserves
source identity between intervals, and fits nonnegative source gains to the
rendered speaker image. Its 11/13/15-direction analysis bases correspond to
7.1.4, 9.1.4, and 9.1.6. Output positions remain free to move. Position
filtering uses a separate 512-sample control clock. OAMD updates retain their
1536-sample cadence. Q15 room-coordinate quantization precedes the signed
OAMD wire grid. Source contributions are summed before reducing precision.

The highest TrueHD substream independently encodes the aggregate PCM, with
minimum channel zero and no inverse compatibility matrix. Dependency-ordered
Q14 channel lifts compete with raw channels on the complete encoded interval
cost. Their integer inverse reconstructs every element sample; LFE never
participates. Prediction candidates must also satisfy the 18 Mbit/s limit
for every access unit before a lower element precision is tried.

The first three substreams carry separately bounded stereo, 5.1, and 7.1
compatibility PCM. Dynamic mode retains at most 18 significant bits in this
independent compatibility core, reserving the transport budget for up to
20-bit immersive elements. Output shifts and DRC analysis follow each
presentation's precision. Swift and Objective-C results, the log, and the
manifest expose `elementBitDepth`, `compatibilityBitDepth`, and `lfeBitDepth`.
LFE remains isolated at 20-bit precision when non-LFE element precision is
reduced to satisfy the transport limit.
Channelbase retains its existing precision policy. Coordinate quantization,
aggregation and presentation precision reduction are lossy preprocessing;
compression is lossless with respect to the admitted presentation PCM.

## Playback and validation scope

For neutral playback checks, encode with `--dialnorm -31`, select the highest
DRP presentation, disable TrueHD DRC and use a labelled multichannel endpoint.
The corresponding speaker layouts are:

| Transport elements | Non-LFE aggregates | Analysis / playback layout |
|---|---|---|
| 12 | 11 | 7.1.4 |
| 14 | 13 | 9.1.4 |
| 16 | 15 | 9.1.6 |

The release validation scope includes DRP GUI identification and playback,
LFE bed identification, height-channel meter activity and decoder alarms.
This does not establish per-video-frame/channel +/-0.5 dB equivalence to a
Dolby reference render. That numerical equivalence remains unqualified.
Spatial reduction and rendering accuracy are separate from lossless recovery
of the encoded element PCM.

Playback verification must be serialized with an exclusive lock. Use monitor
mute for silent checking, preserve native meter timestamps and terminate child
playback on interruption. DRP's native meter cadence and retained peak/decay
state must be accounted for when interpreting video-frame comparisons.

Investigation reports, proprietary reference material, source media and local
measurements stay under ignored `Build/`; they are not SDK dependencies or
public regression fixtures. Production tests use deterministic synthetic
vectors to cover coordinate quantization, moving centroid transitions,
coincident directions, LFE isolation, reversible channel lifting, bounded
plan storage and Swift/Objective-C configuration defaults.
