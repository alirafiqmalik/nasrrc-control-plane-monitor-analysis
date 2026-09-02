#!/usr/bin/env bash
# Replay a local .sdm as live GSMTAP UDP (default 127.0.0.1:4729).
# Use this to develop analyzers without a phone: point Wireshark/tshark at lo.
# With --analyze, pipe the replay straight into the mobility analyzer instead,
# which needs no packet-capture privileges.
# Usage: ./live_replay_sdm.sh [--analyze] <cap.sdm> [layers]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

ANALYZE=0
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --analyze) ANALYZE=1 ;;
    *) ARGS+=("$arg") ;;
  esac
done

SDM="${ARGS[0]:?usage: live_replay_sdm.sh [--analyze] <cap.sdm> [layers]}"
LAYERS="${ARGS[1]:-nas,rrc}"
HOST="${GSMTAP_HOST:-127.0.0.1}"
PORT="${GSMTAP_PORT:-4729}"

if [[ "$ANALYZE" == 1 ]]; then
  need_cmd tshark
  PY="$(scat_python)"
  # mktemp -u would only reserve the name without the .pcap suffix, so take a
  # directory and put the FIFO inside it.
  WORKDIR="$(mktemp -d -t nasrrc-replay-XXXXXX)"
  FIFO="$WORKDIR/stream.pcap"
  mkfifo "$FIFO"
  trap 'rm -rf "$WORKDIR"' EXIT
  echo "[*] replaying $SDM into the analyzer (layers=$LAYERS)" >&2
  # SCAT writes a pcap stream into the FIFO; tshark reads it with -r, so no
  # dumpcap and no capture permission are involved.
  # SCAT's own decode chatter goes to stderr; stdout belongs to the events.
  scat_cmd -t sec -d "$SDM" -L "$LAYERS" -F "$FIFO" >&2 &
  scat_pid=$!
  "$PY" -m nasrrc --fields "$FIFO"
  # SCAT dies on SIGPIPE once the analyzer stops reading; that is a normal end.
  wait "$scat_pid" || true
  exit 0
fi

echo "[*] replaying $SDM as GSMTAP $HOST:$PORT (layers=$LAYERS)"
echo "    listen: tshark -i lo -f 'udp port $PORT and dst host $HOST' -Y 'gsmtap || lte_rrc || nas-eps || nr-rrc || nas-5gs'"
echo "    or:     ./scripts/live_analyze.sh lo"
# -H is GSMTAP host. -a is USB bus:address — do not pass an IP there.
scat_cmd -t sec -d "$SDM" -L "$LAYERS" -H "$HOST" -P "$PORT"
