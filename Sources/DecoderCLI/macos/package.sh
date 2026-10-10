#!/bin/sh
# Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later
set -eu
mkdir -p "$2/Contents/MacOS"
cp "$1" "$2/Contents/MacOS/truehdec"
cp "$3" "$2/Contents/Info.plist"
chmod 755 "$2/Contents/MacOS/truehdec"
