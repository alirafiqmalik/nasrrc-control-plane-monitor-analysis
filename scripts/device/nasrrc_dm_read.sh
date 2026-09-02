#!/system/bin/sh
# Read-only tap on the Shannon DM char node. Writes the raw SDM stream to
# stdout and never writes to the node, so dmd keeps its own DM session and
# keeps logging. Run as root.
#
# The node returns 0 bytes instead of blocking whenever its queue is empty, so
# a single `cat` exits within milliseconds. The loop is what keeps the tap up;
# measured on this Pixel it re-runs about 5 times a second under load.
NODE="${1:-/dev/umts_dm0}"

exec 3<>"$NODE" || exit 1
while :; do
  cat <&3
  sleep 0.02
done
