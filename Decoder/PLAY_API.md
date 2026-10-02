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

Decode and feed run on the producer thread, not in the operating system's render callback. The caller can use short timeouts for FIFO backpressure and network/UI cancellation. Initial device discovery/open is a blocking backend initialization step with its own bounded waits; keep feed off the UI/audio callback thread. No unbounded background input queue is introduced. Existing 48 kHz/FBA/fixed-basis OAMD support and explicit Unknown/discrete-layout rules remain unchanged.

Five alternatives were considered: AU-only playback wrappers, an external codec/player, an unbounded background byte reader, decoding inside the native callback, and a bounded encoded-input session reusing native output. The final option preserves the existing architecture, exact retry state, cross-platform C ABI, and callback deadline constraints.

## CLI

```sh
truehdd play -i INPUT.mlp --layout 2.0
cat INPUT.mlp | truehdd play -i - --layout 2.0
truehdd -i INPUT.mlp --play --layout 7.1.4
```

`play` is the real-time playback subcommand; `--play` remains compatible. `-i -` reads binary stdin, including on Windows. A trimmed end marker finishes a live stdin stream without requiring the transport to close. File export and simultaneous playback use the same decoded player frame.

## Products and ownership

- macOS: Xcode `decoder_framework` -> `libtruehdd.framework`, `decoder_cli` -> `truehdd` (arm64/x86_64).
- Windows: `truehdd.dll`, import library (`truehdd.lib` for MSVC), `truehdd.exe`.
- Linux: `libtruehdd.so.1.1.0` with SONAME `libtruehdd.so.1` and `libtruehdd.so` link, plus `truehdd`.

Shared libraries expose `STHD_API` C symbols; internal C++ symbols are hidden on ELF. CMake propagates `STHD_SHARED` to linked clients and defines `STHD_BUILDING_LIBRARY` only for the library. Manual Windows consumers should define `STHD_SHARED=1` and link the import library. Keep the DLL next to the executable; keep SO files next to the build executable or install under `lib/` with the install RPATH. Use library destroy functions for opaque objects, and never free borrowed strings with the host allocator. Destroy all sessions before unloading a DLL/SO.
