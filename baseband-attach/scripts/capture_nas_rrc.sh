#!/usr/bin/env bash
# Capture LTE/5G NAS + RRC from a rooted Pixel (Shannon modem) over ADB.
# Enables modem logging, drives a registration event, pulls the freshest .sdm.
# Usage: ./capture_nas_rrc.sh [outdir] [--airplane]
# Frozen copy — use ../../scripts/capture_nas_rrc.sh instead.
set -euo pipefail

OUT="${1:-./nas-rrc-capture/$(date +%Y%m%d-%H%M%S)}"
AIRPLANE=0
[[ "${1:-}" == --airplane || "${2:-}" == --airplane ]] && AIRPLANE=1
[[ "${1:-}" == --airplane ]] && OUT="./nas-rrc-capture/$(date +%Y%m%d-%H%M%S)"
SU() { adb shell "su -c '$*'"; }
mkdir -p "$OUT"

echo "[*] device: $(adb shell getprop ro.product.model | tr -d '\r')  root: $(adb shell 'su -c id' | tr -d '\r')"

echo "[*] enabling modem logging (starts dmd)"
SU "setprop persist.vendor.verbose_logging_enabled true"
SU "setprop persist.vendor.sys.modem.logging.enable true"
SU "setprop vendor.modem.logging.shannon_logging true"
sleep 3
SU "date +%s > /data/local/tmp/cap_marker"

if [[ "$AIRPLANE" -eq 1 ]]; then
  SU "cmd connectivity airplane-mode enable"; sleep 4
  SU "cmd connectivity airplane-mode disable"; sleep 20
fi

echo "[*] pulling freshest .sdm"
NEW=$(SU "ls -1t /data/vendor/radio/logs/always-on/sbuff_2026*.sdm /data/vendor/slog/sbuff_2026*.sdm 2>/dev/null | head -1" | tr -d '\r')
[ -n "$NEW" ] || { echo "no .sdm produced — is logging really on?"; exit 1; }
SU "cp $NEW /data/local/tmp/cap.sdm; chmod 644 /data/local/tmp/cap.sdm"
adb pull /data/local/tmp/cap.sdm "$OUT/cap.sdm"

echo "[*] stopping logging + on-device cleanup"
SU "setprop persist.vendor.verbose_logging_enabled false; start modem_logging_stop" || true
SU "rm -f /data/local/tmp/cap.sdm /data/local/tmp/cap_marker" || true

echo "[+] captured: $OUT/cap.sdm"
echo "    decode with: ./decode_nas_rrc.sh $OUT/cap.sdm"
