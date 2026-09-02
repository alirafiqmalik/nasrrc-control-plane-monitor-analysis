#!/usr/bin/env bash
# Ticket 03 — can SCAT own /dev/umts_dm0 instead of dmd?
#
# Throwaway and reversible. Every mode restores what it changed on exit, arms a
# dead-man restore on the device first, and prints the manual restore command.
# This is not part of the live path: scripts/live_tail_ring.sh stays the way to
# stream NAS/RRC, and nothing here is needed to run it.
#
# Usage: ./experiment_scat_diag.sh probe|serial|usb|restore [options]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

DEV_DIR=/data/local/tmp
BRIDGE_DEV="$DEV_DIR/nasrrc_dm_bridge.sh"
READ_DEV="$DEV_DIR/nasrrc_dm_read.sh"
RESTORE_DEV="$DEV_DIR/nasrrc_dm_restore.sh"
NODE="${DM_NODE:-/dev/umts_dm0}"
# The init service is DM-daemon; the process it runs is dmd. `stop dmd` is a
# no-op, which is the trap this ticket exists to record.
DMD_SERVICE=DM-daemon

HOST="${GSMTAP_HOST:-127.0.0.1}"
PORT="${GSMTAP_PORT:-4729}"
LAYERS="${LAYERS:-nas,rrc}"
START_MAGIC="${START_MAGIC:-0x41414141}"
SECS=20
KEEP_DMD=0
PCAP=""

usage() {
  cat <<EOF
Usage: $(basename "$0") <mode> [options]

Modes:
  probe     Report how dmd is started, who holds $NODE, and which USB
            gadget functions exist. Changes nothing.
  node      Stream live GSMTAP by reading $NODE alongside dmd.
            Read-only: nothing is written to the node and dmd keeps
            logging. This is the one that works.
  serial    Suspend dmd, bridge $NODE to a host pty over adb, and run
            SCAT against it. Restores dmd on exit.
  usb       Ask the gadget HAL for the dm/acm/etr_miu debug functions and
            report what enumerates on the host. Restores the gadget on exit.
  restore   Run the device restore script now. Safe at any time.

Options:
  --secs N        seconds to run SCAT in node/serial mode (0 = until Ctrl-C, default $SECS)
  --keep-dmd      serial mode: leave dmd running and open the node alongside it
  --pcap FILE     node/serial mode: write GSMTAP to FILE instead of UDP $HOST:$PORT
  --start-magic X SCAT DM start magic (default $START_MAGIC)

Manual restore, if this script dies:
  adb shell su -c 'sh $RESTORE_DEV'
EOF
}

MODE="${1:-}"
[[ -n "$MODE" ]] || { usage >&2; exit 1; }
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --secs) SECS="$2"; shift 2 ;;
    --keep-dmd) KEEP_DMD=1; shift ;;
    --pcap) PCAP="$2"; shift 2 ;;
    --start-magic) START_MAGIC="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

need_cmd adb

push_device_scripts() {
  adb push -q "$SCRIPT_DIR/device/nasrrc_dm_bridge.sh" "$BRIDGE_DEV" >/dev/null
  adb push -q "$SCRIPT_DIR/device/nasrrc_dm_read.sh" "$READ_DEV" >/dev/null
  adb push -q "$SCRIPT_DIR/device/nasrrc_dm_restore.sh" "$RESTORE_DEV" >/dev/null
}

# A crashed or killed host must not leave the phone with dmd stopped or the USB
# gadget rearranged, so the device restores itself if nothing else does.
arm_deadman() {
  local delay="$1"
  adb shell "su -c 'nohup sh $RESTORE_DEV $delay >/dev/null 2>&1 &'" >/dev/null 2>&1 || true
}

disarm_deadman() {
  adb_su "pkill -f nasrrc_dm_[r]estore" >/dev/null 2>&1 || true
}

dmd_pid() {
  adb_su "pgrep -x dmd" | head -1
}

# `pgrep` exits non-zero once dmd is actually stopped, which is the state this
# script deliberately creates, so an assignment from it must not trip `set -e`.
dmd_pid_or_none() {
  local pid
  pid="$(dmd_pid || true)"
  printf '%s\n' "${pid:-none}"
}

# Toybox lsof is on this image and answers in under a second; walking
# /proc/*/fd over adb takes minutes.
node_holders() {
  adb_su "lsof $NODE 2>/dev/null" | awk 'NR>1 {print $1"("$2")"}' | sort -u | tr '\n' ' '
}

gadget_functions() {
  adb_su "ls /config/usb_gadget/g1/configs/b.1/ | grep -E '^(f[0-9]+|function[0-9]+)$'" | tr '\n' ' '
}

host_usb_interfaces() {
  lsusb -v -d 18d1: 2>/dev/null |
    awk '/bInterfaceNumber/ {n=$2} /iInterface / {$1=""; $2=""; print n":"$0}' |
    sed 's/  */ /g' | sort -u
}

mode_probe() {
  push_device_scripts
  echo "== dmd =="
  echo "init service:  $DMD_SERVICE (process name dmd — 'stop dmd' does nothing)"
  adb_su "cat /vendor/etc/init/dmd.rc" | sed 's/^/  /'
  echo "  init.svc.$DMD_SERVICE = $(adb_su "getprop init.svc.$DMD_SERVICE")"
  echo "  pid = $(dmd_pid_or_none)"
  echo
  echo "== $NODE =="
  adb_su "ls -lZ $NODE" | sed 's/^/  /'
  echo "  fd holders (pids): $(node_holders)"
  # A single `cat` always reports 0: the node returns EOF the moment its queue
  # is empty. The retrying tap is the only honest measure of a second reader.
  echo "  read-only tap, 3 s sample: $(adb_su "timeout 3 sh $READ_DEV $NODE | wc -c") bytes"
  echo
  echo "== USB gadget =="
  echo "  functions built:  $(adb_su 'ls /config/usb_gadget/g1/functions' | tr '\n' ' ')"
  echo "  functions linked: $(adb_su 'ls -l /config/usb_gadget/g1/configs/b.1/' | awk '/->/ {print $NF}' | awk -F/ '{print $NF}' | tr '\n' ' ')"
  echo "  ids: $(adb_su 'cat /config/usb_gadget/g1/idVendor /config/usb_gadget/g1/idProduct' | tr '\n' ':')"
  echo "  persist.vendor.usb.usbradio.config = '$(adb_su 'getprop persist.vendor.usb.usbradio.config')'"
  echo "  host interfaces:"
  host_usb_interfaces | sed 's/^/    /'
}


SCAT_PID=""
READER_PID=""
FIFO=""
PRIOR_VERBOSE=""

# Closing the host end of the adb stream does not reach the on-device reader,
# so it is reaped by name. Two traps in one line:
#   - no spaces in the pattern. `adb_su` single-quotes its argument, so a quoted
#     pattern would collapse into a bare `pkill -f`.
#   - the bracket. Without it the pattern matches the `su -c 'pkill -f ...'`
#     wrapper carrying it, and pkill kills the shell it is running in — which
#     silently truncated everything that followed on the same command line.
reap_remote_readers() {
  adb_su "pkill -f nasrrc_dm_[r]ead" >/dev/null 2>&1 || true
}

# `start modem_logging_stop` is deliberately not used here. It ends the DM
# session for the rest of the boot, and the whole point of this path is that it
# can be run again without a reboot. Only the property this mode changed is put
# back.
node_cleanup() {
  local status=$?
  local pid
  trap '' INT TERM
  trap - EXIT
  echo "[*] stop"

  # The reader goes first so SCAT sees EOF on the FIFO, finishes the packet it
  # is holding and closes its pcap. Killing SCAT first truncates the capture.
  for pid in "$READER_PID"; do
    [[ -n "$pid" ]] || continue
    kill "$pid" 2>/dev/null || true
  done
  reap_remote_readers
  if [[ -n "$SCAT_PID" ]]; then
    kill -INT "$SCAT_PID" 2>/dev/null || true
    for _ in {1..20}; do
      kill -0 "$SCAT_PID" 2>/dev/null || break
      sleep 0.25
    done
    kill -9 "$SCAT_PID" 2>/dev/null || true
  fi

  if [[ -n "$PRIOR_VERBOSE" ]]; then
    echo "    persist.vendor.verbose_logging_enabled -> $PRIOR_VERBOSE"
    adb_su "setprop persist.vendor.verbose_logging_enabled $PRIOR_VERBOSE" >/dev/null 2>&1 || true
  fi
  rm -f "$FIFO"
  exit "$status"
}

# The prize from this ticket. dmd stays up and keeps its own DM session; the
# node hands every reader the same stream, so SCAT sees packets as the modem
# emits them instead of waiting for a ring to be flushed and rotated.
mode_node() {
  need_cmd mkfifo
  push_device_scripts
  reap_remote_readers

  echo "[*] dmd: pid=$(dmd_pid_or_none) holders=$(node_holders)"
  PRIOR_VERBOSE="$(adb_su 'getprop persist.vendor.verbose_logging_enabled')"
  local logging
  logging="$(adb_su 'getprop vendor.sys.modem.logging.status')"
  echo "[*] modem logging status: ${logging:-unknown}"
  if [[ "$logging" != "true" ]]; then
    echo "[*] enabling modem logging (dmd keeps $NODE; this tap only reads it)"
    enable_modem_logging
    sleep 5
    logging="$(adb_su 'getprop vendor.sys.modem.logging.status')"
    [[ "$logging" == "true" ]] || echo "    still $logging — the logger allows about one session per boot; reboot first" >&2
  fi

  # Not *.sdm: that name sends SCAT into the always-on logger parser. The node
  # carries bare SDM frames, which is what `.sdmraw` selects.
  FIFO="${TMPDIR:-/tmp}/nasrrc-node.$$.sdmraw"
  rm -f "$FIFO"
  mkfifo "$FIFO"

  trap node_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  local out=(-H "$HOST" -P "$PORT")
  [[ -n "$PCAP" ]] && out=(-F "$PCAP")
  echo "[*] scat -t sec -d $FIFO ${out[*]}"
  scat_cmd -t sec -d "$FIFO" -L "$LAYERS" "${out[@]}" &
  SCAT_PID=$!

  # `-T` is the raw, pty-free shell protocol. `</dev/null` is not decoration:
  # with a terminal on stdin the same command delivers zero bytes to the host,
  # measured on this machine, while the tap on the device is plainly reading.
  adb shell -T "su -c 'sh $READ_DEV $NODE'" < /dev/null > "$FIFO" &
  READER_PID=$!

  if [[ "$SECS" -gt 0 ]]; then
    echo "[*] running for ${SECS}s"
    sleep "$SECS"
  else
    echo "[*] running until Ctrl-C"
    wait -n "$SCAT_PID" "$READER_PID"
  fi
}

SCAT_PID=""
SOCAT_PID=""
PTY=""
WRAPPER=""

serial_cleanup() {
  local status=$?
  trap '' INT TERM
  trap - EXIT
  echo "[*] restore"
  for pid in "$SCAT_PID" "$SOCAT_PID"; do
    [[ -n "$pid" ]] || continue
    kill "$pid" 2>/dev/null || true
  done
  sleep 1
  for pid in "$SCAT_PID" "$SOCAT_PID"; do
    [[ -n "$pid" ]] || continue
    kill -9 "$pid" 2>/dev/null || true
  done
  adb_su "pkill -f nasrrc_dm_[b]ridge" >/dev/null 2>&1 || true
  adb_su "start $DMD_SERVICE" >/dev/null 2>&1 || true
  disarm_deadman
  rm -f "$WRAPPER" "$PTY"
  sleep 1
  echo "    init.svc.$DMD_SERVICE = $(adb_su "getprop init.svc.$DMD_SERVICE"), dmd pid = $(dmd_pid_or_none), holders = $(node_holders)"
  exit "$status"
}

mode_serial() {
  need_cmd socat
  push_device_scripts

  echo "[*] dmd before: pid=$(dmd_pid_or_none) holders=$(node_holders)"

  # 300 s covers a long run; the host disarms it on a clean exit.
  arm_deadman 300
  trap serial_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if [[ "$KEEP_DMD" -eq 0 ]]; then
    echo "[*] stop $DMD_SERVICE"
    adb_su "stop $DMD_SERVICE" >/dev/null 2>&1 || true
    sleep 2
    echo "    init.svc.$DMD_SERVICE = $(adb_su "getprop init.svc.$DMD_SERVICE"), dmd pid = $(dmd_pid_or_none), holders = $(node_holders)"
  else
    echo "[*] leaving dmd running (--keep-dmd)"
  fi

  PTY="${TMPDIR:-/tmp}/nasrrc-dm.$$.pty"
  WRAPPER="${TMPDIR:-/tmp}/nasrrc-dm.$$.sh"
  # socat EXEC would have to be told about every comma and colon in the adb
  # command line, so the command lives in a file instead.
  cat > "$WRAPPER" <<EOF
#!/bin/sh
exec adb shell -T "su -c 'sh $BRIDGE_DEV $NODE'"
EOF
  chmod +x "$WRAPPER"

  socat "PTY,link=$PTY,rawer,wait-slave" "EXEC:$WRAPPER" &
  SOCAT_PID=$!
  for _ in {1..20}; do
    [[ -e "$PTY" ]] && break
    sleep 0.2
  done
  [[ -e "$PTY" ]] || { echo "socat did not create $PTY" >&2; exit 1; }
  echo "[*] bridge: $NODE <-> $PTY"

  local out=(-H "$HOST" -P "$PORT")
  [[ -n "$PCAP" ]] && out=(-F "$PCAP")
  echo "[*] scat -t sec -s $PTY --start-magic $START_MAGIC ${out[*]}"
  scat_cmd -t sec -s "$PTY" --no-rts --no-dsr --start-magic "$START_MAGIC" \
    -L "$LAYERS" "${out[@]}" &
  SCAT_PID=$!

  if [[ "$SECS" -gt 0 ]]; then
    echo "[*] running for ${SECS}s"
    sleep "$SECS"
  else
    echo "[*] running until Ctrl-C"
    wait "$SCAT_PID"
  fi
}

usb_cleanup() {
  local status=$?
  trap '' INT TERM
  trap - EXIT
  echo "[*] restore USB gadget"
  # Not an inline setprop: adb_su wraps its argument in single quotes, so a ''
  # argument closes and reopens that quoting and setprop silently gets one arg.
  adb_su "sh $RESTORE_DEV" >/dev/null 2>&1 || true
  sleep 5
  adb wait-for-device
  disarm_deadman
  echo "    persist.vendor.usb.usbradio.config = '$(adb_su 'getprop persist.vendor.usb.usbradio.config')'"
  echo "    linked: $(adb_su 'ls -l /config/usb_gadget/g1/configs/b.1/' | awk '/->/ {print $NF}' | awk -F/ '{print $NF}' | tr '\n' ' ')"
  exit "$status"
}

mode_usb() {
  push_device_scripts
  echo "[*] before:"
  host_usb_interfaces | sed 's/^/    /'

  # If the gadget comes back without adb, the phone has to fix itself.
  arm_deadman 90
  trap usb_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  echo "[*] persist.vendor.usb.usbradio.config = dm  (re-triggers usbd)"
  adb_su "setprop persist.vendor.usb.usbradio.config dm; setprop vendor.usb.config dm" >/dev/null 2>&1 || true
  sleep 6
  adb wait-for-device
  echo "[*] after:"
  host_usb_interfaces | sed 's/^/    /'
  echo "    linked: $(adb_su 'ls -l /config/usb_gadget/g1/configs/b.1/' | awk '/->/ {print $NF}' | awk -F/ '{print $NF}' | tr '\n' ' ')"
  echo "    ids: $(adb_su 'cat /config/usb_gadget/g1/idVendor /config/usb_gadget/g1/idProduct' | tr '\n' ':')"
  echo "    lsusb: $(lsusb | grep -i 18d1 || true)"
}

case "$MODE" in
  probe) mode_probe ;;
  node) mode_node ;;
  serial) mode_serial ;;
  usb) mode_usb ;;
  restore)
    push_device_scripts
    adb_su "sh $RESTORE_DEV"
    sleep 2
    echo "init.svc.$DMD_SERVICE = $(adb_su "getprop init.svc.$DMD_SERVICE"), dmd pid = $(dmd_pid_or_none), holders = $(node_holders)"
    ;;
  *) echo "unknown mode: $MODE" >&2; usage >&2; exit 1 ;;
esac
