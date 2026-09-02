#!/usr/bin/env bash
# Print NAS/RRC mobility events: measurement reports with measId and RSRP/RSRQ,
# and handovers that really carry mobilityControlInfo.
#
#   ./live_analyze.sh                 # capture on lo (needs capture rights)
#   ./live_analyze.sh eth0            # capture on another interface
#   ./live_analyze.sh cap.pcap        # a saved GSMTAP pcap
#   ./live_analyze.sh /tmp/scat.pcap  # a FIFO another process is writing
#
# Live capture goes through dumpcap, so the user must be able to run it. Reading
# a pcap or a FIFO does not.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

SOURCE="${1:-lo}"
shift || true
HOST="${GSMTAP_HOST:-127.0.0.1}"
PORT="${GSMTAP_PORT:-4729}"

need_cmd tshark
PY="$(scat_python)"

if [[ -e "$SOURCE" ]]; then
  echo "[*] analyzing $SOURCE" >&2
  exec "$PY" -m nasrrc --fields "$SOURCE" "$@"
fi

# --host keeps a second radio (eSIM) out: SCAT sends radio 0 to the configured
# address and any further radio to the next one.
echo "[*] analyzing GSMTAP on $SOURCE ($HOST:$PORT) — Ctrl-C to stop" >&2
exec "$PY" -m nasrrc --interface "$SOURCE" --port "$PORT" --host "$HOST" "$@"
