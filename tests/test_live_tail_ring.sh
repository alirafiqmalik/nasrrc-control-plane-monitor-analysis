#!/usr/bin/env bash
# Ring-follower proof. No device: a fake `adb` and a fake SCAT stand in.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d)"
trap 'stop_script; rm -rf "$TMPROOT"' EXIT

FAILURES=0
PID=""

fail() {
  echo "FAIL [$SCENARIO]: $1" >&2
  echo "--- script log ---" >&2
  cat "$TMP/live.log" >&2
  FAILURES=$(( FAILURES + 1 ))
}

stop_script() {
  [[ -n "$PID" ]] || return 0
  kill "$PID" 2>/dev/null
  wait "$PID" 2>/dev/null
  PID=""
}

# The fake device. FAKE_NO_RINGS hides every ring; FAKE_STAT_FAILS makes the
# first N `stat` calls fail the way a rotated-away ring does.
write_fake_adb() {
  cat > "$TMP/bin/adb" <<'ADB'
#!/usr/bin/env bash
all="$*"
case "$1" in
  exec-out)
    ring="${all##*-f }"; ring="${ring//\'/}"; ring="${ring%% *}"
    [[ -f "$FAKE_STATE/rings/${ring##*/}" ]] && cat "$FAKE_STATE/rings/${ring##*/}"
    exec sleep 300 ;;
  shell)
    if [[ "$all" == *"ls -1"* ]]; then
      [[ -n "${FAKE_NO_RINGS:-}" ]] || cat "$FAKE_STATE/current_ring"
    elif [[ "$all" == *"stat -c %s"* ]]; then
      n=$(( $(cat "$FAKE_STATE/stats" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$FAKE_STATE/stats"
      if (( n <= ${FAKE_STAT_FAILS:-0} )); then
        echo "stat: cannot stat: No such file or directory" >&2
        exit 1
      fi
      s=$(( $(cat "$FAKE_STATE/size" 2>/dev/null || echo 0) + 1000 ))
      echo "$s" > "$FAKE_STATE/size"; echo "$s"
    else echo "$all" >> "$FAKE_STATE/props.log"; fi ;;
esac
exit 0
ADB
  cat > "$TMP/bin/fakepy" <<'PY'
#!/usr/bin/env bash
prev=""; fifo=""
for a in "$@"; do [[ "$prev" == "-d" ]] && fifo="$a"; prev="$a"; done
exec cat "$fifo" >> "$SCAT_OUT"
PY
  chmod +x "$TMP/bin/adb" "$TMP/bin/fakepy"
}

setup() {
  SCENARIO="$1"
  TMP="$TMPROOT/$1"
  export FAKE_STATE="$TMP/state" SCAT_OUT="$TMP/scat.out"
  mkdir -p "$TMP/bin" "$FAKE_STATE/rings"
  : > "$SCAT_OUT"
  : > "$FAKE_STATE/props.log"
  printf 'RINGAAA payload\n' > "$FAKE_STATE/rings/sbuff_00000001.sdm"
  printf 'RINGBBB payload\n' > "$FAKE_STATE/rings/sbuff_00000002.sdm"
  echo /data/vendor/slog/sbuff_00000001.sdm > "$FAKE_STATE/current_ring"
  write_fake_adb
}

run_script() {
  PATH="$TMP/bin:$PATH" SCAT_PY="$TMP/bin/fakepy" FIFO="$TMP/live.sdm" TMPDIR="$TMP" \
    POLL_SECS=1 DRAIN_SECS=1 GSMTAP_HOST=127.0.0.1 GSMTAP_PORT=47290 LAYERS=nas,rrc \
    "$@" "$ROOT/scripts/live_tail_ring.sh" > "$TMP/live.log" 2>&1 &
  PID=$!
}

wait_for() { # pattern file timeout_deciseconds
  local i=0
  while (( i < $3 )); do grep -q "$1" "$2" 2>/dev/null && return 0; sleep 0.1; i=$((i+1)); done
  return 1
}

# --- follows a rotation, restores logging, reaps with a quote-safe pattern ----
setup rotation
run_script env
wait_for RINGAAA "$SCAT_OUT" 100 || fail "first ring never reached the FIFO"
echo /data/vendor/slog/sbuff_00000002.sdm > "$FAKE_STATE/current_ring"
wait_for RINGBBB "$SCAT_OUT" 150 || fail "rotation not followed: stream stayed pinned to the first ring"

kill -TERM "$PID" 2>/dev/null
wait_for 'verbose_logging_enabled false' "$FAKE_STATE/props.log" 100 || fail "logging not restored on stop"
wait "$PID" 2>/dev/null
PID=""

# `adb_su` wraps its argument in single quotes, so a reap pattern that contains
# its own quotes collapses to `pkill -f tail` on the device and matches every
# unrelated tail there. Assert the pattern reaches adb as one unquoted token.
grep -q "pkill -f [^ ']*/data/vendor/" "$FAKE_STATE/props.log" \
  || fail "reap pattern lost its /data/vendor/ qualifier: $(grep pkill "$FAKE_STATE/props.log" | head -1)"
grep -q "pkill -f '" "$FAKE_STATE/props.log" \
  && fail "reap pattern is quoted; adb_su will collapse it to 'pkill -f tail'"
# Rotation reaps only the ring it left, so a second instance keeps its stream.
grep -q "pkill -f [^ ']*/data/vendor/slog/sbuff_00000001.sdm" "$FAKE_STATE/props.log" \
  || fail "rotation reap was not scoped to the ring it left"


# --- says why it stopped when the device has no ring -------------------------
setup no-rings
FAKE_NO_RINGS=1 run_script env FAKE_NO_RINGS=1
wait "$PID" 2>/dev/null; RC=$?
PID=""
(( RC == 1 )) || fail "expected exit 1 with no ring on the device, got $RC"
grep -q 'no sbuff_\*.sdm yet' "$TMP/live.log" \
  || fail "no explanation printed; set -e aborted before the message"


# --- survives a stat that races a rotation -----------------------------------
setup stat-races
run_script env FAKE_STAT_FAILS=2
wait_for RINGAAA "$SCAT_OUT" 200 || fail "a failed stat during the startup probe ended the run"
stop_script


if (( FAILURES )); then
  echo "$FAILURES scenario(s) failed" >&2
  exit 1
fi
echo "PASS: rotation, missing ring, racing stat"
