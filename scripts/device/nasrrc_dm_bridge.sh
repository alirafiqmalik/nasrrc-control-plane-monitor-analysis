#!/system/bin/sh
# Bridge the Shannon DM char node to stdin/stdout so host SCAT can drive it
# over `adb shell -T`. stdin -> node (SCAT control writes), node -> stdout
# (the SDM stream). Run as root. Ticket 03; see .scratch/live-analyzer/issues/.
#
# The read half is nasrrc_dm_read.sh, which opens its own descriptor on the
# node — the node serves every reader, so there is no reason to duplicate the
# retry loop here. This script only adds the write direction.
NODE="${1:-/dev/umts_dm0}"
case "$0" in
  */*) READER_SCRIPT="${0%/*}/nasrrc_dm_read.sh" ;;
  *)   READER_SCRIPT="./nasrrc_dm_read.sh" ;;
esac

sh "$READER_SCRIPT" "$NODE" &
READER=$!
trap 'kill "$READER" 2>/dev/null' EXIT INT TERM

exec 3<>"$NODE" || exit 1
# Returns when the host closes the connection, which then reaps the reader.
cat >&3
