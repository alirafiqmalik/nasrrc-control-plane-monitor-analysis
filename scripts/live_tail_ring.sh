#!/usr/bin/env bash
# Stream NAS/RRC until Ctrl-C. Does not change radio state unless --airplane.
# Usage: ./live_tail_ring.sh [--airplane]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

AIRPLANE=0
usage() {
  cat <<EOF
Usage: $(basename "$0") [--airplane]

Stream the on-device dmd ring (sbuff_*.sdm) to host SCAT as GSMTAP on UDP 4729.
Runs until Ctrl-C. Does not toggle eSIM or radio state.

  --airplane   one airplane-mode cycle after the stream is up, then keep listening
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --airplane) AIRPLANE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

need_cmd adb
need_cmd mkfifo

HOST="${GSMTAP_HOST:-127.0.0.1}"
PORT="${GSMTAP_PORT:-4729}"
LAYERS="${LAYERS:-nas,rrc}"
FIFO="${FIFO:-/tmp/nasrrc-live.sdm}"
# Measured rotation interval on this Pixel is ~9 s, with bursts 5.5-6.6 s apart.
POLL_SECS="${POLL_SECS:-2}"
# Let the rotated ring drain to EOF before detaching from it.
DRAIN_SECS="${DRAIN_SECS:-2}"
# A quiet radio looks exactly like a stalled ring, so wait out several rotation
# intervals before concluding dmd has stopped writing.
STALL_POLLS="${STALL_POLLS:-15}"
# The logger tolerates about one session per boot; asking it to restart forever
# wedges it for the rest of the boot, so give up after a few attempts.
FLUSH_LIMIT="${FLUSH_LIMIT:-3}"
SCAT_PID=""
STREAM_PID=""
FOLLOW_PID=""
# stream_rings runs as a subshell, so its `adb exec-out` pid has to travel back
# to cleanup through the filesystem rather than through a variable.
FOLLOW_PID_FILE="${TMPDIR:-/tmp}/nasrrc-live.$$.follow"

ring_name() {
  printf '%s\n' "${1##*/}"
}

# Newest timestamped session, by filename. `ls -1t` is mtime order and a ring
# still being flushed can outrank the session that replaced it. Prefer slog
# (the live file) over the always-on copy of the same name.
latest_ring() {
  local listing name
  listing="$(adb_su "ls -1 /data/vendor/radio/logs/always-on/sbuff_[0-9]*.sdm /data/vendor/slog/sbuff_[0-9]*.sdm 2>/dev/null")"
  name="$(printf '%s\n' "$listing" | awk -F/ '{print $NF}' | sort | tail -1)"
  [[ -n "$name" ]] || return 1
  if printf '%s\n' "$listing" | grep -F -q "/slog/$name"; then
    printf '%s\n' "/data/vendor/slog/$name"
  else
    printf '%s\n' "/data/vendor/radio/logs/always-on/$name"
  fi
}

ring_size() {
  adb_su "stat -c %s '$1'"
}

# A ring can rotate away between latest_ring and the stat that follows — routine
# at the ~9 s interval this device uses. Anything that is not a plain number
# counts as zero, because letting `set -e` end the run here costs a reboot: the
# logger allows about one session per boot.
ring_size_or_zero() {
  local size
  size="$(ring_size "$1" 2>/dev/null || true)"
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  printf '%s\n' "$size"
}

# Kill every remote tail this tool leaves behind. Closing `adb exec-out` locally
# does not reach the on-device process, so it has to be reaped by name.
#
# The pattern carries no spaces and no quotes on purpose. `adb_su` wraps its
# argument in single quotes, so a quoted pattern collapses into `pkill -f tail`
# on the device — which would match every unrelated `tail` there. Each `.` here
# stands for one literal character of `tail -c +1 -f /data/vendor/`.
#
# Pass a ring path to reap only that one. The bare form sweeps every ring tail on
# the device, which is what start and stop want but would also cut a concurrent
# instance's stream, so rotation passes the ring it is leaving.
reap_remote_tails() {
  local scope="${1:-/data/vendor/}"
  adb_su "pkill -f tail.-c..1.-f.${scope}" >/dev/null 2>&1 || true
}

# Reattach across dmd session rotation. `tail -f` never returns on a ring that
# stopped growing, so it runs in the background and is replaced when a newer
# timestamped session appears. The new ring is read from byte 0, so the bytes
# written between the rotation and the poll are not lost.
stream_rings() {
  local current=""
  local ring="$1"
  local stalled=0
  local flushes=0
  local next
  local size=""
  local next_size

  # This runs as a subshell, so it owns the teardown of its own remote tail.
  trap 'kill "$FOLLOW_PID" 2>/dev/null || true; exit 0' TERM INT

  while true; do
    # Ring names sort by session time, so a plain string compare keeps the
    # follower monotone. `ls -1t` orders by mtime, and a ring still being
    # flushed can outrank the newer session that replaced it — reattaching
    # backwards would replay its whole multi-MB history as fresh GSMTAP.
    if [[ "$(ring_name "$ring")" > "$(ring_name "$current")" ]]; then
      if [[ -n "$FOLLOW_PID" ]]; then
        sleep "$DRAIN_SECS"
        kill "$FOLLOW_PID" 2>/dev/null || true
        wait "$FOLLOW_PID" 2>/dev/null || true
        reap_remote_tails "$current"
      fi
      current="$ring"
      size=""
      adb exec-out "su -c 'tail -c +1 -f $current'" &
      FOLLOW_PID=$!
      echo "$FOLLOW_PID" > "$FOLLOW_PID_FILE"
      stalled=0
    fi

    sleep "$POLL_SECS"

    # No watchdog on the remote tail. Measured on the device 2026-09-02: killing
    # it leaves the `sh -c su -c ...` wrapper alive, so the host `adb exec-out`
    # survives and a host-side liveness check never fires; and a device-side
    # `pgrep -f` self-matches its own wrapper, so it always reports a hit. The
    # stream recovers on its own at the next rotation, which cost one rotation
    # interval (~30 s) in that test.
    next="$(latest_ring || true)"
    [[ -n "$next" ]] || continue
    next_size="$(ring_size "$next" 2>/dev/null || true)"

    if [[ -n "$next_size" && "$(ring_name "$next")" == "$(ring_name "$current")" && "$next_size" == "$size" ]]; then
      # Same session, readable, and not being written to.
      stalled=$(( stalled + 1 ))
      if (( stalled >= STALL_POLLS )); then
        if (( flushes < FLUSH_LIMIT )); then
          adb_su "start modem_logging_start" >/dev/null 2>&1 || true
          flushes=$(( flushes + 1 ))
        elif (( flushes == FLUSH_LIMIT )); then
          echo "[*] ring stalled and dmd will not restart — reboot to log again" >&2
          flushes=$(( flushes + 1 ))
        fi
        stalled=0
      fi
    else
      stalled=0
    fi
    size="$next_size"
    ring="$next"
  done
}

# Restore logging first, then tear down. A second Ctrl-C used to land in the
# grace period and kill the script with logging still enabled on the device, so
# interrupts are ignored for the rest of teardown.
cleanup() {
  local status=$?
  local pid
  trap '' INT TERM
  trap - EXIT
  echo "[*] stop — restoring logging"
  disable_modem_logging
  # stream_rings only sees TERM once its `sleep` returns, which can outlast the
  # grace below, so the follower is killed here by the pid it recorded.
  FOLLOW_PID="$(cat "$FOLLOW_PID_FILE" 2>/dev/null || true)"
  for pid in "$STREAM_PID" "$FOLLOW_PID" "$SCAT_PID"; do
    [[ -n "$pid" ]] || continue
    kill "$pid" 2>/dev/null || true
  done
  sleep 1
  for pid in "$STREAM_PID" "$FOLLOW_PID" "$SCAT_PID"; do
    [[ -n "$pid" ]] || continue
    kill -9 "$pid" 2>/dev/null || true
  done
  reap_remote_tails
  rm -f "$FIFO" "$FOLLOW_PID_FILE"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "[*] enabling modem logging (dmd keeps /dev/umts_dm0)"
reap_remote_tails
enable_modem_logging

SBUFF="$(latest_ring || true)"
[ -n "$SBUFF" ] || { echo "no sbuff_*.sdm yet — enable Verbose Vendor Logging?" >&2; exit 1; }
SBUFF_SIZE="$(ring_size_or_zero "$SBUFF")"
# Logging is live if the ring grows, or if dmd opens a newer session — under a
# short rotation interval the ring is replaced before it is ever seen to grow.
RING_GROWING=0
for _ in {1..10}; do
  sleep 1
  CANDIDATE="$(latest_ring || true)"
  [[ -n "$CANDIDATE" ]] || continue
  CANDIDATE_SIZE="$(ring_size_or_zero "$CANDIDATE")"
  if [[ "$(ring_name "$CANDIDATE")" != "$(ring_name "$SBUFF")" ]] || (( CANDIDATE_SIZE > SBUFF_SIZE )); then
    RING_GROWING=1
    SBUFF="$CANDIDATE"
    break
  fi
  SBUFF="$CANDIDATE"
  SBUFF_SIZE="$CANDIDATE_SIZE"
done
if [[ "$RING_GROWING" -ne 1 ]]; then
  echo "newest ring did not grow after logging was enabled: $SBUFF" >&2
  exit 1
fi
echo "[*] ring: $SBUFF"

rm -f "$FIFO"
mkfifo "$FIFO"

echo "[*] live GSMTAP $HOST:$PORT  (stop: Ctrl-C)"
echo "    tshark -i lo -f 'udp port $PORT and dst host $HOST' -Y 'gsmtap || lte_rrc || nas-eps || nr-rrc || nas-5gs'"

scat_cmd -t sec -d "$FIFO" -L "$LAYERS" -H "$HOST" -P "$PORT" &
SCAT_PID=$!
stream_rings "$SBUFF" > "$FIFO" &
STREAM_PID=$!

if [[ "$AIRPLANE" -eq 1 ]]; then
  sleep 1
  airplane_cycle
  echo "[*] still listening until Ctrl-C"
fi

wait -n "$SCAT_PID" "$STREAM_PID"
