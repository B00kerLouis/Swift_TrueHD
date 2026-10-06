# Decoder research fixtures

Copyright (c) 2026 B00kerLouis. LGPL-2.1-or-later.

These four streams contain original deterministic synthetic audio. They contain
no Dolby/demo/movie source tracks. They may be redistributed as Decoder test
media under the Decoder license; Encoder research restrictions do not apply.

The plain 7.1 stream was generated from eight integer PCM channels with sample
value `(((n * (c + 1) + c * 17) % 97) - 48) * (c + 1) * 256`.
Immersive source channels use `(((n / 64 + c * 17) % 97) - 48) * (c + 1) * 256`,
with integer division. The source contains an eight-channel bed and eight fixed
height feeds. The unmodified Swift Encoder generated 12/14/16-element streams
at 20-bit coded precision, restoring 24-bit PCM through output shift.

Temporary Swift generation/oracle code and packed reference PCM are retained in
ignored `Build/FFmpegAdapter/`, outside Decoder products. The oracle used spatial
preparation, quantization, transport basis, independent presentation matrices,
output shift and channel assignments before entropy encoding; it did not use
this Decoder. `references.json` preserves MD5/SHA-256 for each reference PCM and
the compressed media. FATE definitions use those independently generated MD5s.

The 7.1 stream has 129 AUs / 5,137 samples; each immersive stream has 161 AUs /
6,417 samples. Final AUs deliver 17 samples, trimming 23. Restart 124 in the
immersive streams occurs before the following OAMD update, exercising explicit
metadata unavailability and subsequent recovery after seek.
