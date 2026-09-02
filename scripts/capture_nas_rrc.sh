#!/usr/bin/env bash
# Snapshot the current SDM ring to a file. Does not change radio state unless --airplane.
# Usage: ./capture_nas_rrc.sh [outdir] [--airplane]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

need_cmd adb

OUT=""
AIRPLANE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --airplane) AIRPLANE=1; shift ;;
    -h|--help)
      echo "Usage: $(basename "$0") [outdir] [--airplane]"
      exit 0 ;;
    *)
      if [[ -n "$OUT" ]]; then
        echo "unknown argument: $1" >&2
        exit 1
      fi
      OUT="$1"
      shift ;;
  esac
done
OUT="${OUT:-./captures/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"

echo "[*] device: $(adb shell getprop ro.product.model | tr -d '\r')  root: $(adb_su id)"
echo "[*] enabling modem logging"
enable_modem_logging
sleep 3

if [[ "$AIRPLANE" -eq 1 ]]; then
  airplane_cycle
fi

echo "[*] pulling freshest .sdm"
NEW="$(adb_su "ls -1t /data/vendor/radio/logs/always-on/sbuff_*.sdm /data/vendor/slog/sbuff_*.sdm 2>/dev/null | head -1")"
[ -n "$NEW" ] || { echo "no .sdm produced — is logging really on?" >&2; exit 1; }
adb_su "cp $NEW /data/local/tmp/cap.sdm; chmod 644 /data/local/tmp/cap.sdm"
adb pull /data/local/tmp/cap.sdm "$OUT/cap.sdm"

echo "[*] stopping logging"
disable_modem_logging
adb_su "rm -f /data/local/tmp/cap.sdm" || true

echo "[+] captured: $OUT/cap.sdm"
echo "    decode with: $SCRIPT_DIR/decode_nas_rrc.sh $OUT/cap.sdm"
