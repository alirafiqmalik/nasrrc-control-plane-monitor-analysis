#!/usr/bin/env bash
# Replay a local .sdm as live GSMTAP UDP (default 127.0.0.1:4729).
# Use this to develop analyzers without a phone: point Wireshark/tshark at lo.
# Usage: ./live_replay_sdm.sh <cap.sdm> [layers]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

SDM="${1:?usage: live_replay_sdm.sh <cap.sdm> [layers]}"
LAYERS="${2:-nas,rrc}"
HOST="${GSMTAP_HOST:-127.0.0.1}"
PORT="${GSMTAP_PORT:-4729}"

echo "[*] replaying $SDM as GSMTAP $HOST:$PORT (layers=$LAYERS)"
echo "    listen: tshark -i lo -f 'udp port $PORT and dst host $HOST' -Y 'gsmtap || lte_rrc || nas-eps || nr-rrc || nas-5gs'"
# -H is GSMTAP host. -a is USB bus:address — do not pass an IP there.
scat_cmd -t sec -d "$SDM" -L "$LAYERS" -H "$HOST" -P "$PORT"
