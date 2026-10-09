# Real-time encoded playback API (C ABI v3)

`sthd_player_*` combines the existing decoder, presentation/renderer and native audio backend. It accepts arbitrary TrueHD elementary-stream byte chunks, including partial four-byte headers, partial access units and many access units in one call. It does not require an intermediate PCM file, aligned caller input, or a second decoder.

## Lifecycle

1. Initialize `STHDPlayerOptions`: `struct_size=sizeof(options)`, explicit linear `gain`, optional actual speaker layout, and Windows immersive PCM fallback policy.
2. Call `sthd_player_create`. Construction does not open a device; the first successfully decoded AU selects and opens output.
3. Call `sthd_player_feed` from one producer thread. Always advance the input pointer by `consumed`, including on `STHD_TIMEOUT`.
4. Retry remaining bytes after backpressure. If all bytes were accepted but the last frame remains pending, `feed(player,NULL,0,...)` retries that frame. It is never decoded or enqueued twice.
5. On end of input, `sthd_player_finish` rejects truncated input and drains the native device. A timeout can be retried; success closes the audio backend and keeps final counters/last frame for inspection. Feeding a finished session is invalid.
6. `sthd_player_cancel` can be called concurrently from a control thread. It signals the native FIFO, interrupts waits and stops output on the producer thread. Other methods, including destruction, remain externally serialized.
7. `sthd_player_destroy` releases objects through the owning library runtime.

```c
#include "TrueHDDecoder.h"
STHDPlayerOptions options = {0};
options.struct_size = sizeof(options);
options.gain = 1.0f;
options.explicit_layout = 1;
sthd_layout_named("2.0", &options.layout);
char error[256];
STHDPlayer *player = sthd_player_create(&options, error, sizeof(error));
/* For each incoming transport chunk, advance by consumed even on TIMEOUT. */
size_t consumed = 0;
STHDStatus result = sthd_player_feed(player, encoded_bytes, byte_count,
                                     &consumed, 100);
/* Retry the remaining chunk or feed NULL/0 when result is TIMEOUT. */
/* At explicit EOF: */
result = sthd_player_finish(player, 5000);
sthd_player_destroy(player);
```

A fatal bitstream/device error is sticky. Destroy and create a new session to change streams or devices. `sthd_player_stats` reports accepted bytes, decoded AUs/samples, pending frame, buffered bytes and native submitted/consumed/underrun counters. `sthd_player_last_frame` copies the latest successfully decoded PCM frame without rerunning the codec. `sthd_abi_version()` returns 3.

## Boundaries and real-time constraints

The player has one 8190-byte AU buffer and one 40-sample pending PCM frame. The native FIFO remains bounded to 16,384 frames, and the render callback still performs no decode, file I/O or allocation. Timeout retains exact transport/decoder progress rather than dropping or duplicating data. The final trim controls actual delivered PCM sample count. Bytes after a trim end marker are rejected.

Decode and feed run on the producer thread, not in the operating system's render callback. The caller can use short timeouts for FIFO backpressure and network/UI cancellation. Initial device discovery/open is a blocking backend initialization step with its own bounded waits; keep feed off the UI/audio callback thread. No unbounded background input queue is introduced. Existing 48 kHz/FBA/OAMD support and explicit Unknown/discrete-layout rules remain unchanged.

Five alternatives were considered: AU-only playback wrappers, an external codec/player, an unbounded background byte reader, decoding inside the native callback, and a bounded encoded-input session reusing native output. The final option preserves the existing architecture, exact retry state, cross-platform C ABI, and callback deadline constraints.

## Decoder reset and random access

`sthd_decoder_reset` clears stream state without changing ABI v3. A host may
resume at a complete major-sync AU in the middle of a stream. The first restart
after creation/reset has no available preceding PCM interval, so its preceding
interval checksum is not compared. Restart CRC, AU/substream integrity and all
subsequent interval checks remain active. Hosts own byte resynchronization and
external timestamps; `first_sample` starts at zero after reset. Player sessions
still use the lifecycle above; the FFmpeg adapter calls the Decoder C ABI.

Major sync does not necessarily repeat OAMD. Element PCM is still returned after
random access when coordinates are unavailable: `positions_valid=0` until an
OAMD update arrives. Raw extraction is valid; positional presentation views and
rendering continue to require valid coordinates. A new native player needs that
metadata for object output, whereas the FFmpeg adapter can return unspecified
element channels and explicitly mark positions unavailable.

Decoder 1.2.0 adds `sthd_decoder_drc_valid(decoder)` without changing frame
layout or ABI v3. Bit i means presentation i has received a DRC gain update.
Query it immediately after successful decode under the instance's existing
serialization. Reset clears the mask; failures preserve it. Missing updates
after seek are marked unavailable rather than treated as known unity gain.

## CLI

```sh
truehdec play -i INPUT.mlp --layout 2.0
cat INPUT.mlp | truehdec play -i - --layout 2.0
truehdec -i INPUT.mlp --play --layout 7.1.4
```

`play` is the real-time playback subcommand; `--play` remains compatible. `-i -` reads binary stdin, including on Windows. A trimmed end marker finishes a live stdin stream without requiring the transport to close. File export and simultaneous playback use the same decoded player frame.

## Products and ownership

- macOS: Xcode `libtruehdec` -> `libtruehdec.framework`, `truehdec` -> `truehdec` (arm64/x86_64).
- Windows: `truehdec.dll`, import library (`truehdec.lib` for MSVC), `truehdec.exe`.
- Linux: `libtruehdec.so.1.4.1` with SONAME `libtruehdec.so.1` and `libtruehdec.so` link, plus `truehdec`.

Shared libraries expose `STHD_API` C symbols; internal C++ symbols are hidden on ELF. CMake propagates `STHD_SHARED` to linked clients and defines `STHD_BUILDING_LIBRARY` only for the library. Manual Windows consumers should define `STHD_SHARED=1` and link the import library. Keep the DLL next to the executable; keep SO files next to the build executable or install under `lib/` with the install RPATH. Use library destroy functions for opaque objects, and never free borrowed strings with the host allocator. Destroy all sessions before unloading a DLL/SO.

`auto` is resolved from each platform endpoint at run time. Device tags/labels, WAVE speaker masks, PipeWire positions, and an applicable OS-declared stereo pair are mapping evidence; channel counts alone are not. No test-machine channel layout is persisted into the player.

## Decoder 1.3 timed positions and PCM checks

The unchanged C ABI v3 frame keeps the last PCM sample's position snapshot.
`sthd_decoder_motion` and `sthd_player_last_motion` copy a bounded
`STHDFrameMotion`: per-sample coordinates, validity bitmap and one incoming
OAMD target update with sample offset/ramp duration. Failed AU decoding preserves
the previous view. A stream reset clears coordinates, pending updates and counters.
Pending targets can start in later AUs; one bounded 64-entry queue covers the
supported maximum 2047-sample offset. Interrupted ramps begin from the evaluated
current position. A first target supplies coordinates when it starts; no prior
position is invented after random access.

Use `sthd_render_motion` or `sthd_audio_write_motion` to retain motion. Legacy
frame-only calls use the snapshot. The player retains both PCM and motion on
backpressure, so retry never double-decodes or publishes a future position early.
Windows positional output queues coordinates beside PCM and sets object positions
from the first consumed sample of each native quantum. The OS API applies that
position to the quantum, so native object movement has engine quantum granularity;
PCM rendering evaluates every sample. Windows physical playback remains untested.

`sthd_decoder_pcm_checksum` / `sthd_player_pcm_checksum` expose the last AU's
checked/mismatched presentation masks, expected/actual bytes and cumulative mismatch
count. Default playback continues on PCM-check mismatches and reports them; all
transport CRC/parity/authentication failures still reject input. Set
`sthd_decoder_set_strict_pcm_checksum` / `sthd_player_set_strict_pcm_checksum`
to 1 to reject a PCM mismatch transactionally. Setters use the same producer
serialization as feed/decode. Reset preserves policy. CLI `--verify-only` and
`--strict-pcm-checksum` select strict checks; ordinary decode/play reports a first
warning and the final mismatch count. These checks refer to the preceding decoded
restart interval; they cannot certify a final interval lacking a following restart.

Element file sidecars stream target updates with absolute sample times and ramp
lengths, then label the final coordinate snapshot's sample and dynamic flag. Memory
usage does not grow with programme length. Existing refusal/cleanup behavior applies
jointly to PCM and sidecars.

## Decoder 1.4 coordinate preroll

Targets may arrive before a valid position trace at startup or after reset.
When the prior ramp origin is unknown, `valid_samples`/`positions_valid` stay
unavailable until the first target ramp completes. Stereo/5.1/7.1 PCM output
plans use the core presentation and remain available; positional/height output
requires valid coordinates and host preroll. This changes no struct layout or
C ABI version. The FFmpeg dictionary additionally exports incoming targets as
`truehdd.oamd.targets_xyz_f32le`, independently of coordinate validity.

## Decoder 1.4.1 explicit termination

A termination marker can preserve all 40 samples, including an explicit zero
trim count. EOS is tracked independently of sample shortening. The copied
frame/ABI v3 layout is unchanged. `sthd_decoder_end_of_stream` and
`sthd_player_end_of_stream` report validated bitstream termination; ordinary
host EOF is a separate event. Queries follow existing producer serialization,
NULL returns zero, failed decode preserves the flag and reset clears it.
The player recognizes zero-trim EOS before accepting more bytes, retains the
pending frame on timeout, and still requires finish/drain to complete playback.
CLI rejects trailing file data after any terminator and keeps its existing
output cleanup behavior. Version 1.4.1 handles both the explicit trim form and
the repeated termination-word form without removing valid PCM samples.
