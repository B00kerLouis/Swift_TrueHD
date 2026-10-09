#!/usr/bin/env sh
# SPDX-License-Identifier: LGPL-2.1-or-later
# Validate a built minimal FFmpeg adapter without requiring the Swift encoder.
set -eu
ffmpeg_source="$1"
output_directory="$2"
integration_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$output_directory"
task_cc="${CC:-cc}"
task_cflags=$(pkg-config --cflags truehdec)
task_libraries=$(pkg-config --static --libs truehdec)
task_library_directory=$(pkg-config --variable=libdir truehdec)
export LD_LIBRARY_PATH="$task_library_directory${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# FFmpeg/pkg-config installations used here must have paths without whitespace.
"$task_cc" -std=c11 -Wall -Wextra -Werror $task_cflags -I"$ffmpeg_source" \
    "$integration_directory/adapter_test.c" \
    "$ffmpeg_source/libavcodec/libavcodec.a" "$ffmpeg_source/libavutil/libavutil.a" \
    $task_libraries -lm -pthread -o "$output_directory/adapter_test"
for profile in 71 12 14 16; do
    for layer in 0 1 2; do
        "$output_directory/adapter_test" \
            "$integration_directory/fixtures/synthetic-$profile.mlp" - "$layer"
    done
    if [ "$profile" != 71 ]; then
        "$output_directory/adapter_test" \
            "$integration_directory/fixtures/synthetic-$profile.mlp" - 3
    fi
done
"$output_directory/adapter_test" "$integration_directory/fixtures/timed-16.mlp" - 3
mkdir -p "$output_directory/samples/libtruehdd"
cp "$integration_directory"/fixtures/*.mlp "$output_directory/samples/libtruehdd/"
make -C "$ffmpeg_source" -j4 fate-libtruehdd \
    SAMPLES="$output_directory/samples" TARGET_PATH="$ffmpeg_source"
