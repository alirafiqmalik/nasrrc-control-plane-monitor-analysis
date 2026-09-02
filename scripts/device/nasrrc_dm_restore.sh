#!/system/bin/sh
# Undo everything the ticket-03 experiment changes. Safe to run at any time,
# and safe to run twice. Optional argument: seconds to wait first, so the host
# can arm it as a dead-man switch before touching anything.
#
#   adb shell su -c 'sh /data/local/tmp/nasrrc_dm_restore.sh'
DELAY="${1:-0}"
[ "$DELAY" -gt 0 ] 2>/dev/null && sleep "$DELAY"

# No spaces in the pattern: an outer `su -c '...'` eats the quoting. The
# bracket keeps the pattern from matching the command line carrying it.
pkill -f nasrrc_dm_[b]ridge 2>/dev/null
pkill -f nasrrc_dm_[r]ead 2>/dev/null

# The dm/acm/etr_miu USB gadget functions are off unless this property is set.
setprop persist.vendor.usb.usbradio.config ""
# Any change to vendor.usb.config restarts usbd, which re-applies the gadget
# from sys.usb.config. sys.usb.config itself is never touched: a wrong value
# there costs adb.
setprop vendor.usb.config adb

# dmd's SocketAgent port. Empty is the shipped value.
setprop persist.vendor.config.dm_server_port ""

start DM-daemon
