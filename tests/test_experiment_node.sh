#!/usr/bin/env bash
# DM-node tap proof. No device: a fake `adb` serves canned SDM bytes and a fake
# SCAT stands in for the decoder.
#
# The two failures this locks down both cost real device runs:
#   - the reader gets `< /dev/null`. With a terminal on stdin, `adb shell -T`
#     hands the host zero bytes while the tap on the phone is reading fine.
#   - teardown stops the reader before SCAT, so SCAT reaches EOF and flushes.
#     Killing SCAT first truncates the capture to a bare pcap header.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

FAILURES=0
SCENARIO=""

fail() {
  echo "FAIL [$SCENARIO]: $1" >&2
  echo "--- script log ---" >&2
  cat "$TMP/run.log" >&2
  FAILURES=$(( FAILURES + 1 ))
}

# The fake device. It answers the property reads the script makes, records the
# commands it was given, and serves $FAKE_STATE/stream for the read tap.
write_fake_adb() {
  cat > "$TMP/bin/adb" <<'ADB'
#!/usr/bin/env bash
all="$*"
echo "$all" >> "$FAKE_STATE/calls"
case "$1" in
  push) exit 0 ;;
  shell)
    if [[ "$all" == *"nasrrc_dm_read.sh"* ]]; then
      # The live tap: canned bytes, then stay attached like the real loop.
      cat "$FAKE_STATE/stream"
      exec sleep 300
    elif [[ "$all" == *"/data/vendor/slog/sbuff_"* ]]; then
      cat "$FAKE_STATE/ring" 2>/dev/null
    elif [[ "$all" == *getprop* ]]; then
      # `shell su -c 'getprop <name>'` — the name is the last token, minus the
      # quote adb_su wrapped the whole command in.
      name="${all##* }"; name="${name%\'}"
      cat "$FAKE_STATE/props/$name" 2>/dev/null
    elif [[ "$all" == *setprop* ]]; then
      rest="${all#*setprop }"; rest="${rest%\'}"
      name="${rest%% *}"
      value="${rest#"$name"}"; value="${value# }"
      printf '%s\n' "$value" > "$FAKE_STATE/props/$name"
    elif [[ "$all" == *"pgrep -x dmd"* ]]; then
      echo 1234
    elif [[ "$all" == *lsof* ]]; then
      echo "COMMAND PID"
      echo "dmd 1234"
    fi
    exit 0 ;;
esac
exit 0
ADB
  chmod +x "$TMP/bin/adb"
}

# The fake SCAT only produces output once its input reaches EOF, which is what
# makes the teardown order observable.
write_fake_scat() {
  cat > "$TMP/bin/fakescat" <<'SCAT'
#!/usr/bin/env bash
fifo=""; out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) fifo="$2"; shift 2 ;;
    -F) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
echo "$fifo" > "$FAKE_STATE/scat_input"
cat "$fifo" > "$out.partial"
mv "$out.partial" "$out"
SCAT
  chmod +x "$TMP/bin/fakescat"
}

# lib.sh's enable_modem_logging flips three properties, so the fake device has
# to hold all three and the script has to put all three back.
LOGGING_PROPS=(
  persist.vendor.verbose_logging_enabled
  persist.vendor.sys.modem.logging.enable
  vendor.modem.logging.shannon_logging
)

set_props() {
  local p
  for p in "${LOGGING_PROPS[@]}"; do echo "$1" > "$FAKE_STATE/props/$p"; done
  echo "$2" > "$FAKE_STATE/props/vendor.sys.modem.logging.status"
}

setup() {
  TMP="$TMPROOT/$SCENARIO"
  FAKE_STATE="$TMP/state"
  mkdir -p "$TMP/bin" "$FAKE_STATE/props"
  : > "$FAKE_STATE/calls"
  echo /data/vendor/slog/sbuff_20260902110000.sdm > "$FAKE_STATE/ring"
  set_props true true
  printf 'SDM-CANNED-STREAM-BYTES\n' > "$FAKE_STATE/stream"
  write_fake_adb
  write_fake_scat
  export FAKE_STATE
}

run_node() {
  # No settle wait: the fake device has no session to come up.
  PATH="$TMP/bin:$PATH" FAKE_STATE="$FAKE_STATE" SCAT_PY="$TMP/bin/fakescat" \
    LOGGING_WAIT_SECS=3 \
    "$ROOT/scripts/experiment_scat_diag.sh" node --secs 2 --pcap "$TMP/out.pcap" \
    > "$TMP/run.log" 2>&1
}

# --- a dry tap and a silent decoder must not look the same ---
SCENARIO="tap byte count reported"
# (checked after the first run below)

# --- no session ring means no stream; say so instead of taping a dead node ---
SCENARIO="no session ring is refused"
setup
: > "$FAKE_STATE/ring"
set_props false false
run_node
if [[ -f "$TMP/out.pcap" ]]; then
  fail "ran the tap with no session ring on the device"
fi
if ! grep -q "no session ring" "$TMP/run.log"; then
  fail "no explanation of why the run stopped"
fi
for prop in "${LOGGING_PROPS[@]}"; do
  got="$(cat "$FAKE_STATE/props/$prop" 2>/dev/null)"
  [[ "$got" == "false" ]] || fail "$prop left at '$got' after the early exit"
done

# --- the tap reaches the decoder, and the decoder gets to finish ---
SCENARIO="stream reaches scat and flushes"
setup
run_node
if [[ ! -f "$TMP/out.pcap" ]]; then
  fail "scat produced no output — it was killed before the FIFO reached EOF"
elif ! grep -q SDM-CANNED-STREAM-BYTES "$TMP/out.pcap"; then
  fail "the tap's bytes never reached scat"
fi
SCENARIO="tap byte count reported"
if ! grep -q "tap delivered [0-9]* bytes" "$TMP/run.log"; then
  fail "stop did not report how many bytes the tap delivered"
fi

# --- raw SDM, not the always-on logger wrapping ---
SCENARIO="fifo selects the raw sdm parser"
if [[ "$(cat "$FAKE_STATE/scat_input" 2>/dev/null)" != *.sdmraw ]]; then
  fail "scat input is not a *.sdmraw fifo: $(cat "$FAKE_STATE/scat_input" 2>/dev/null)"
fi

# --- the reader is not given a terminal ---
SCENARIO="reader stdin is redirected"
if ! grep -F '$READ_DEV $NODE' "$ROOT/scripts/experiment_scat_diag.sh" | grep -qF '< /dev/null'; then
  fail "the read tap is not invoked with < /dev/null"
fi

# --- logging is left as it was found, without ending the session ---
SCENARIO="prior logging state restored"
setup
set_props false false
run_node
for prop in "${LOGGING_PROPS[@]}"; do
  got="$(cat "$FAKE_STATE/props/$prop" 2>/dev/null)"
  [[ "$got" == "false" ]] || fail "$prop left at '$got', not false"
done
if grep -q modem_logging_stop "$FAKE_STATE/calls"; then
  fail "teardown ran modem_logging_stop, which ends the session for the boot"
fi

# --- the on-device reader is reaped; closing the host end does not reach it ---
SCENARIO="remote reader reaped"
if ! grep -q "pkill -f nasrrc_dm_" "$FAKE_STATE/calls"; then
  fail "the on-device reader was never reaped"
fi
# The reap pattern must not match the command line carrying it, or pkill kills
# the shell it is running in.
if grep -q "pkill -f nasrrc_dm_read" "$FAKE_STATE/calls"; then
  fail "the reap pattern self-matches; it needs a bracket, e.g. nasrrc_dm_[r]ead"
fi

if (( FAILURES > 0 )); then
  echo "$FAILURES failure(s)" >&2
  exit 1
fi
echo "PASS: node tap streams, flushes, and restores"
