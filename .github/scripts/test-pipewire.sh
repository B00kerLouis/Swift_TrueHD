#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Native API integration test: isolated server and a labelled virtual sink.
set -euo pipefail
smoke_binary="$1"
player_binary="$2"
encoded_fixture="$3"
export XDG_RUNTIME_DIR
XDG_RUNTIME_DIR="$(mktemp -d)"
chmod 700 "$XDG_RUNTIME_DIR"
pipewire > "$XDG_RUNTIME_DIR/pipewire.log" 2>&1 &
pw_pid=$!
wireplumber > "$XDG_RUNTIME_DIR/wireplumber.log" 2>&1 &
wp_pid=$!
cleanup() {
  result=$?
  if [[ "$result" -ne 0 ]]; then
    cat "$XDG_RUNTIME_DIR/pipewire.log" "$XDG_RUNTIME_DIR/wireplumber.log" || true
    pw-dump || true
  fi
  kill "$wp_pid" "$pw_pid" 2>/dev/null || true
  wait "$wp_pid" "$pw_pid" 2>/dev/null || true
}
trap cleanup EXIT
for attempt in $(seq 1 50); do
  if pw-cli info 0 >/dev/null 2>&1; then break; fi
  sleep 0.1
done
previous_id=""
while IFS='|' read -r layout count positions; do
  if [[ -n "$previous_id" ]]; then pw-cli destroy "$previous_id"; fi
  pw-cli create-node adapter "{ factory.name = support.null-audio-sink node.name = sthd-ci media.class = Audio/Sink object.linger = true audio.rate = 48000 audio.channels = $count audio.position = [ $positions ] }"
  for attempt in $(seq 1 50); do
    previous_id="$(pw-dump | jq -r '.[] | select(.info.props."node.name" == "sthd-ci") | .id' | head -1)"
    if [[ -n "$previous_id" ]]; then break; fi
    sleep 0.1
  done
  [[ -n "$previous_id" ]]
  pw-metadata -n default 0 default.audio.sink Spa:String:JSON '{"name":"sthd-ci"}' || true
  sleep 0.5
  "$smoke_binary" | tee "$XDG_RUNTIME_DIR/result-$layout.log"
  grep -q "channels=$count submitted=48000 consumed=48000" "$XDG_RUNTIME_DIR/result-$layout.log"
  "$player_binary" "$encoded_fixture" | tee "$XDG_RUNTIME_DIR/player-$layout.log"
  grep -q "decoded=12345 submitted=12345 consumed=12345" "$XDG_RUNTIME_DIR/player-$layout.log"
done <<'LAYOUTS'
2.0|2|FL FR
5.1|6|FL FR FC LFE SL SR
7.1|8|FL FR FC LFE RL RR SL SR
5.1.2|8|FL FR FC LFE SL SR TSL TSR
5.1.4|10|FL FR FC LFE SL SR TFL TFR TRL TRR
7.1.2|10|FL FR FC LFE RL RR SL SR TSL TSR
7.1.4|12|FL FR FC LFE RL RR SL SR TFL TFR TRL TRR
7.1.6|14|FL FR FC LFE RL RR SL SR TFL TFR TRL TRR TSL TSR
9.1.6|16|FL FR FC LFE RL RR SL SR TFL TFR TRL TRR TSL TSR FLW FRW
5.1-back|6|FL FR FC LFE RL RR
7.1-reversed|8|SR SL RR RL LFE FC FR FL
7.1.4-reversed|12|TRR TRL TFR TFL SR SL RR RL LFE FC FR FL
9.1.6-reversed|16|FRW FLW TSR TSL TRR TRL TFR TFL SR SL RR RL LFE FC FR FL
LAYOUTS

# Unpositioned hardware slots are not a speaker map, even at a familiar count.
pw-cli destroy "$previous_id"
pw-cli create-node adapter '{ factory.name = support.null-audio-sink node.name = sthd-ci media.class = Audio/Sink object.linger = true audio.rate = 48000 audio.channels = 16 audio.position = [ AUX0 AUX1 AUX2 AUX3 AUX4 AUX5 AUX6 AUX7 AUX8 AUX9 AUX10 AUX11 AUX12 AUX13 AUX14 AUX15 ] }'
sleep 0.5
set +e
"$smoke_binary" > "$XDG_RUNTIME_DIR/discrete.log" 2>&1
unknown_result=$?
set -e
cat "$XDG_RUNTIME_DIR/discrete.log"
[[ "$unknown_result" -eq 2 ]]
grep -q 'unknown speaker layout' "$XDG_RUNTIME_DIR/discrete.log"
