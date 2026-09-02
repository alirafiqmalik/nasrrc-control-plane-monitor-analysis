# Shared helpers for NAS/RRC scripts. Source from the other scripts in this directory.
# shellcheck shell=bash

NASRRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

scat_python() {
  if [[ -n "${SCAT_PY:-}" ]]; then
    printf '%s\n' "$SCAT_PY"
    return
  fi
  if [[ -x "$NASRRC_ROOT/.venv/bin/python" ]]; then
    printf '%s\n' "$NASRRC_ROOT/.venv/bin/python"
    return
  fi
  echo "SCAT python not found. Run scripts/setup_venv.sh (or set SCAT_PY)." >&2
  return 1
}

scat_cmd() {
  local py
  py="$(scat_python)"
  "$py" -m scat.main "$@"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    return 1
  }
}

adb_su() {
  adb shell "su -c '$*'" | tr -d '\r'
}

enable_modem_logging() {
  adb_su "setprop persist.vendor.verbose_logging_enabled true"
  adb_su "setprop persist.vendor.sys.modem.logging.enable true"
  adb_su "setprop vendor.modem.logging.shannon_logging true"
}

disable_modem_logging() {
  adb_su "setprop persist.vendor.verbose_logging_enabled false; start modem_logging_stop" || true
}

# Optional one-shot reattach. Never the default — live monitoring stays up until Ctrl-C.
airplane_cycle() {
  echo "[*] airplane cycle"
  adb_su "cmd connectivity airplane-mode enable"
  sleep 4
  adb_su "cmd connectivity airplane-mode disable"
  sleep 20
}
