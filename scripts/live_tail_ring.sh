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
STARTED_AT="$(adb_su "date +%s")"
SCAT_PID=""
TAIL_PID=""

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ -n "$SCAT_PID" || -n "$TAIL_PID" ]]; then
    [[ -z "$SCAT_PID" ]] || kill "$SCAT_PID" 2>/dev/null || true
    [[ -z "$TAIL_PID" ]] || kill "$TAIL_PID" 2>/dev/null || true
    [[ -z "$SCAT_PID" ]] || wait "$SCAT_PID" 2>/dev/null || true
    [[ -z "$TAIL_PID" ]] || wait "$TAIL_PID" 2>/dev/null || true
  fi
  echo "[*] stop — restoring logging"
  disable_modem_logging
  rm -f "$FIFO"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "[*] enabling modem logging (dmd keeps /dev/umts_dm0)"
enable_modem_logging
sleep 3

SBUFF="$(adb_su "ls -1t /data/vendor/radio/logs/always-on/sbuff_[0-9]*.sdm /data/vendor/slog/sbuff_[0-9]*.sdm 2>/dev/null | head -1")"
[ -n "$SBUFF" ] || { echo "no sbuff_*.sdm yet — enable Verbose Vendor Logging?" >&2; exit 1; }
SBUFF_MTIME="$(adb_su "stat -c %Y '$SBUFF'")"
if (( SBUFF_MTIME < STARTED_AT )); then
  echo "newest timestamped ring was not updated after logging was enabled: $SBUFF" >&2
  exit 1
fi
echo "[*] ring: $SBUFF"

rm -f "$FIFO"
mkfifo "$FIFO"

echo "[*] live GSMTAP $HOST:$PORT  (stop: Ctrl-C)"
echo "    tshark -i lo -f 'udp port $PORT' -Y 'lte_rrc || nas-eps || nr-rrc || nas-5gs'"

scat_cmd -t sec -d "$FIFO" -L "$LAYERS" -H "$HOST" -P "$PORT" &
SCAT_PID=$!
adb exec-out "su -c 'tail -c +1 -f $SBUFF'" > "$FIFO" &
TAIL_PID=$!

if [[ "$AIRPLANE" -eq 1 ]]; then
  sleep 1
  airplane_cycle
  echo "[*] still listening until Ctrl-C"
fi

wait -n "$SCAT_PID" "$TAIL_PID"
