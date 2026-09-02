# 03 — Experiment: SCAT owns /dev/umts_dm0

**What to build:** A throwaway, reversible test of whether SCAT can run on-device (or via USB DM `-u`) against `/dev/umts_dm0` after suspending `dmd`, plus a documented restore path. True realtime is the prize; do not replace the tail-the-ring path unless this is reliable.

**Blocked by:** None — isolated experiment. Keep 01 working regardless of outcome.

**Status:** resolved

- [x] Record how `dmd` is started (not a normal `stop dmd` service)
- [x] Attempt SCAT serial on the phone with a restore script ready
- [x] If USB DM works on this Pixel, document vendor/product/interface and start-magic
- [x] Write the result into `map.md` (works / respawns / bricks logging until reboot)

## Comments
Host `scat -s /dev/umts_dm0` cannot work: that node is on the Pixel. See `plan-device-live.md`.

## Answer

SCAT does not need to own `/dev/umts_dm0`, and cannot. The node hands the same
live SDM stream to every reader, so SCAT reads it **alongside** dmd. That is
true realtime, and it is what `scripts/experiment_scat_diag.sh node` does.

`scripts/experiment_scat_diag.sh` has four modes — `probe` (changes nothing),
`node` (the working path), `serial` (the failed one), `restore`. Every
destructive mode arms `/data/local/tmp/nasrrc_dm_restore.sh` on the device as a
dead-man switch first, so a killed host still puts the phone back.

### How dmd is started

`/vendor/etc/init/dmd.rc` declares `service DM-daemon /vendor/bin/dmd`, class
`main`, user `system`. The **service** is `DM-daemon`; the **process** is `dmd`.
`stop dmd` is a silent no-op — the trap this ticket was written to record. The
reversible control is `stop DM-daemon` / `start DM-daemon`, and init does bring
it back with a new pid holding the node again.

Stopping it costs the boot's logging session: after `start DM-daemon` the daemon
runs, but `vendor.sys.modem.logging.status` stays false and no ring is written
until a reboot. Measured twice.

### The read-only tap (works)

`/dev/umts_dm0` opens for a second reader while dmd holds it, and it mirrors
rather than steals: over one 25 s window the tap took 9.1 MB while dmd's ring
still grew 14,685,987 → 20,981,219 bytes. The bytes are bare SDM frames
(`7f` … `7e`), so SCAT parses them through `run_diag`, and a FIFO named
`*.sdmraw` is what selects that path (`.sdm` would pick the logger parser).

Proof run, 60 s with dmd untouched: 30 GSMTAP frames — RRC reconfiguration and
complete, measurement reports, paging, SIB3/4/5/8/15/24, MIB, a detach request
and a service accept. Arrivals are continuous: median inter-arrival 44 ms,
longest gap 8.1 s on an idle stationary UE, against the ring path's ~30 s
rotation cadence. First packet lands ~3 s after the tap attaches.

Two things the node path does not fix: it still needs a DM session running
(`vendor.sys.modem.logging.status=true`), which is still about one per boot; and
`sbuff_power_on_log.sdm` still owns the first seconds after boot.

The tap is a shell loop, not one `cat`. The node returns 0 bytes rather than
blocking when its queue is empty, so a single `cat` sees EOF and exits within
milliseconds — it reported `0` on a link that was carrying 700 KB/s. The loop
re-runs about 5 times a second under load.

The host plumbing needs `< /dev/null`. `adb shell -T "su -c '...'"` with a
terminal on stdin delivered **zero bytes** to the host while the same tap on the
device was plainly reading; with stdin redirected it delivered 3.6 MB in 8 s.

### SCAT driving the node (fails)

With dmd suspended and the node free, SCAT's `init_diag` reaches it byte for
byte — verified by bridging the pty to a file instead and reading back the exact
20-byte `CONTROL_START` frame `7f120000 0f000000 a0000000 00000041 4141417e`.
The modem answers nothing, with dmd stopped or running, so `-F` wrote an empty
pcap both times.

The reason is in dmd: it links `liboemservice.so` and registers an OEM service
(`OEM_OnRequest type=%d id=%d`, `COMMAND_SET_DM_MODE`, `COMMAND_STOP_DM`). The
DM session is started over the vendor RIL path, not by writing SDM control
frames to the char node. Writing the start magic to the node is therefore inert,
and the default `--start-magic 0x41414141` was never the problem.

### USB DM (blocked by the build type)

The gadget function exists — `/config/usb_gadget/g1/functions/dm.gs7`, created by
`init.gs201.usb.rc:58` and chowned to `system` — and dmd has a `UsbAgent` bound
to `/dev/ttyGS1`. It still cannot be enabled on this phone.

`android.hardware.usb.gadget-service` links `dm.gs7`, `acm.gs6` and
`etr_miu.gs11` when its vendor-functions string is exactly `dm`
(disassembly at `0x80c4`: length 2, then `cmp` against `0x6d64`). But
`getVendorFunctions()` at `0x9590` reads `ro.build.type` first, compares it to
`user` (`0x72657375`), and on a match returns the literal `"user"` at `0x9634`
without ever reading `persist.vendor.usb.usbradio.config` or
`vendor.usb.config`. `ro.build.type` is `user` here.

Confirmed on the device: setting `persist.vendor.usb.usbradio.config=dm` and
restarting `usbd` re-enumerated the gadget as `18d1:4ee7` with `ffs.adb` alone.
No vendor/product/interface to document — a userdebug build would be needed
first, so `scat -u` stays untested.

Cost of the experiment: three reboots, and USB fell back to adb-only
(`18d1:4ee7`, NCM gone) until the USB preference is set again.
