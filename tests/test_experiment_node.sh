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
    elif [[ "$all" == *"getprop persist.vendor.verbose_logging_enabled"* ]]; then
      cat "$FAKE_STATE/verbose"
    elif [[ "$all" == *"getprop vendor.sys.modem.logging.status"* ]]; then
      cat "$FAKE_STATE/logging"
    elif [[ "$all" == *"setprop persist.vendor.verbose_logging_enabled"* ]]; then
      v="${all##* }"; printf '%s\n' "${v%\'}" > "$FAKE_STATE/verbose"
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

setup() {
  TMP="$TMPROOT/$SCENARIO"
  FAKE_STATE="$TMP/state"
  mkdir -p "$TMP/bin" "$FAKE_STATE"
  : > "$FAKE_STATE/calls"
  echo true > "$FAKE_STATE/logging"
  echo true > "$FAKE_STATE/verbose"
  printf 'SDM-CANNED-STREAM-BYTES\n' > "$FAKE_STATE/stream"
  write_fake_adb
  write_fake_scat
  export FAKE_STATE
}

run_node() {
  PATH="$TMP/bin:$PATH" FAKE_STATE="$FAKE_STATE" SCAT_PY="$TMP/bin/fakescat" \
    "$ROOT/scripts/experiment_scat_diag.sh" node --secs 2 --pcap "$TMP/out.pcap" \
    > "$TMP/run.log" 2>&1
}

# --- the tap reaches the decoder, and the decoder gets to finish ---
SCENARIO="stream reaches scat and flushes"
setup
run_node
if [[ ! -f "$TMP/out.pcap" ]]; then
  fail "scat produced no output — it was killed before the FIFO reached EOF"
elif ! grep -q SDM-CANNED-STREAM-BYTES "$TMP/out.pcap"; then
  fail "the tap's bytes never reached scat"
fi

# --- raw SDM, not the always-on logger wrapping ---
SCENARIO="fifo selects the raw sdm parser"
if [[ "$(cat "$FAKE_STATE/scat_input" 2>/dev/null)" != *.sdmraw ]]; then
  fail "scat input is not a *.sdmraw fifo: $(cat "$FAKE_STATE/scat_input" 2>/dev/null)"
fi

# --- the reader is not given a terminal ---
SCENARIO="reader stdin is redirected"
if ! grep -q 'nasrrc_dm_read\|\$READ_DEV' "$ROOT/scripts/experiment_scat_diag.sh" ||
   ! grep -qF '< /dev/null > "$FIFO"' "$ROOT/scripts/experiment_scat_diag.sh"; then
  fail "the read tap is not invoked with < /dev/null"
fi

# --- logging is left as it was found, without ending the session ---
SCENARIO="prior logging state restored"
setup
echo false > "$FAKE_STATE/verbose"
echo false > "$FAKE_STATE/logging"
run_node
if [[ "$(cat "$FAKE_STATE/verbose")" != "false" ]]; then
  fail "persist.vendor.verbose_logging_enabled left at $(cat "$FAKE_STATE/verbose"), not false"
fi
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
