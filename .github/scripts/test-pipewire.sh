#!/usr/bin/env bash
# Native API integration test: isolated server and a labelled virtual sink.
set -euo pipefail
smoke_binary="$1"
export XDG_RUNTIME_DIR
XDG_RUNTIME_DIR="$(mktemp -d)"
chmod 700 "$XDG_RUNTIME_DIR"
pipewire > "$XDG_RUNTIME_DIR/pipewire.log" 2>&1 &
pw_pid=$!
wireplumber > "$XDG_RUNTIME_DIR/wireplumber.log" 2>&1 &
wp_pid=$!
cleanup() {
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
LAYOUTS
