# FIR2 / FIR4 / LPC8 prediction

Author: B00kerLouis.

The Swift encoder supports `auto`, `fir2`, `fir4`, `lpc8` and `none` prediction
search modes. The public configuration is `TrueHDEncoderConfiguration.predictionMode`;
the CLI option is `--prediction`. FIR2/FIR4 cap the existing fixed predictor
ladder at order 2/4. LPC8 additionally admits data-derived orders 1 through 8.
Each mode retains raw coding when it costs less. These are predictor search
caps, not DTS-style 2/4/8 partitions and not a requirement to predict every
channel at the maximum order.

```sh
Build/Products/Release/truehda -i SOURCE.wav -o OUTPUT.mlp --prediction auto
Build/Products/Release/truehda -i SOURCE.wav -o LPC8.mlp --prediction lpc8 --dialnorm -31
```

`--dialnorm -31` sets neutral dialogue normalization in every presentation for
PCM qualification. DRC metadata analysis uses the selected normalization too.
Unspecified dialnorm preserves the existing stereo -30 and multichannel -24
defaults. DRP applies dialnorm even when DRC is disabled; its normalized output
at other values must not be mistaken for a predictive coding error. The public
configuration stores positive magnitudes 1...31, with zero selecting defaults.
Both options are copied with the configuration and recorded in companion logs.

## Candidate selection and state

Every quantized LPC order is scored on the residual it actually produces,
including Huffman payload, LSBs, offset inheritance/change and FIR signalling.
One bounded restart interval supplies untapered and Hann-tapered autocorrelation
analyses. Tapering removes boundary-cut bias from coefficient estimation; it
never windows, scales or changes the PCM being encoded. Short-block LPC analysis
also remains a candidate for local signal changes.

The ordinary encoder reads at most one restart interval into its analysis
buffer. Atmos reuses the already prepared interval. In `auto`, Atmos serializes
complete FIR2, FIR4 and LPC8 interval candidates with independent entropy/filter
state and commits the smallest in source order. An interval's analysis filters
are immutable across its candidate encodes. No encoder dependency or Swift
source is added to a decoder target.

Prediction uses the transmitted fixed-point coefficients, signed Int64 dot
products, arithmetic right shifts and wrap32 subtraction. History contains
original reconstructed samples, newest first. Raw coding still updates it.
At a restart, eight unpredicted samples replace the complete FIR history before
prediction resumes. Changing/removing a filter is explicitly signalled; an
unchanged filter remains inherited. The production residual calculation is:

```text
prediction = wrap32(floor(sum(history[k] * coefficient[k]) / 2^shift))
residual = wrap32(original - prediction)
history = original samples, newest first
```

## Playback levels and validation

The ordinary encoder emits major-sync presentation flags `0x7C`; Atmos uses
`0xFC`. The decoder also accepts legacy `0x3C` fixtures.

Playback level comparison allows a ±0.5 dB difference from Dolby rendering.
This tolerance concerns rendered levels; encoded element PCM remains subject
to exact sample comparison. Disable DRC and account for presentation dialnorm
when comparing levels. Layouts without heights use compatibility presentations;
height layouts use positional elements, whose LFE occupies element 0.

DRP is the decoded-PCM oracle for prediction qualification. Spatial reduction
and element quantization occur before predictive compression; losslessness of
encoded elements does not imply losslessness to the original IAB source tracks.
Research reports, programme media and proprietary tools are retained locally
and are not distributed with the encoder or decoder.
