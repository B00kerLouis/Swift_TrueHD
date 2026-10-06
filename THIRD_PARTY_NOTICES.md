# Third-party references and license boundaries

The component licenses are described in [LICENSE](LICENSE). They cover only
rights controlled by the project's rights holder. They do not relicense
third-party material.

## FFmpeg

`Sources/Swift_TrueHD/Encoding/MLPHuffman.swift` identifies `libavcodec/mlp.c`
as the source of the fixed MLP codebook tables. Other Encoder comments reference
FFmpeg's arithmetic and encoding approaches. The Decoder's
[bitstream record](Decoder/BITSTREAM.md) records comparison with FFmpeg's MLP
decoder. Decoder 1.4 incorporates the attributed dither lookup constants
described below; its parsing and stream state remain native C/C++. These references are preserved; this notice does not certify that
all referenced material is an independently authored, relicensable contribution.

- [FFmpeg MLP tables and checksums](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/mlp.c)
- [FFmpeg MLP/TrueHD decoder](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/mlpdec.c)
- [FFmpeg licensing](https://ffmpeg.org/legal.html)

The cited FFmpeg files carry LGPL-2.1-or-later notices. Their existing copyright
and license notices continue to apply to any protected material taken from
them; the Encoder Research License imposes no additional restrictions on such
material. If source code or a protected adaptation is incorporated, its full
upstream notices must accompany it. The LGPL text is included in
`LICENSES/LGPL-2.1-or-later.txt`.

## Native audio and format documentation

The Decoder uses CoreAudio/AudioToolbox, WASAPI/Windows Spatial Audio, PipeWire
and optional ALSA interfaces. Those system or external libraries retain their
own licenses. Changing this repository's license grants no rights to
redistribute them.

Dolby layout documents, Microsoft interface documentation and ALSA interface
references are linked in `Decoder/BITSTREAM.md` and `Decoder/AUDIO_ARCHITECTURE.md`.
Reference documents, supplied media and proprietary reference tools are not
relicensed or included as Decoder dependencies by these notices.

## Decoder dither constants

`Sources/DecoderFramework/Decoder.cpp` includes the TrueHD dither lookup table
published in FFmpeg `libavcodec/mlpdec.c` (revision
`2da55bf59a68801a8157ab141a487196ce3416a8`), copyright (c) 2007-2008 Ian Caulfield,
under LGPL-2.1-or-later. The full license is provided in
`LICENSES/LGPL-2.1-or-later.txt`. The scalar decoder uses the table with its own
bounded C++ stream state and arithmetic implementation.

Extended matrix field interpretation was cross-checked against the primary
`truehdd/truehdd` source at revision `02d29cd0f8f9163d8951a4a33e55328a2261bf8a`.
The Rust crate is a research reference only and is not linked or included in any
Decoder product. OAMD timing tables are specified in ETSI TS 103 420, table 23.
