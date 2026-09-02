#!/system/bin/sh
# Bridge the Shannon DM char node to stdin/stdout so host SCAT can drive it
# over `adb shell -T`. stdin -> node (SCAT control writes), node -> stdout
# (the SDM stream). Run as root. Ticket 03; see .scratch/live-analyzer/issues/.
#
# The node returns 0 bytes rather than blocking when its queue is empty, so a
# plain `cat` sees EOF and exits before the modem has answered anything. The
# reader therefore loops instead of trusting the first EOF.
NODE="${1:-/dev/umts_dm0}"

exec 3<>"$NODE" || exit 1

while :; do
  cat <&3
  sleep 0.02
done &
READER=$!
trap 'kill "$READER" 2>/dev/null' EXIT INT TERM

# Returns when the host closes the connection, which then reaps the reader.
cat >&3
