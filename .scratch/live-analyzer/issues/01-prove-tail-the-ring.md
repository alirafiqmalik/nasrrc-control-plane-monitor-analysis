# 01 — Prove tail-the-ring GSMTAP on the Pixel

**What to build:** With the phone USB-connected and rooted, `scripts/live_tail_ring.sh` streams NAS/RRC GSMTAP on UDP 4729 until Ctrl-C. Restore logging props on stop.

**Blocked by:** None — can start immediately (script exists; this is the device proof).

**Status:** resolved

- [x] Verbose vendor logging actually produces a growing `sbuff_*.sdm`
- [x] SCAT on the host parses the FIFO (logger path) without treating it as raw SDM
- [x] tshark on `lo` udp/4729 shows NAS/RRC while the stream runs (no radio poke required)
- [x] `--airplane` is optional and a subsequent Ctrl-C still restores logging
- [x] Note measured latency (dmd flush → tshark line) in `map.md`

## Comments
Follow `.scratch/live-analyzer/plan-device-live.md`. Do not open `/dev/umts_dm0` from the host. Do not toggle eSIM.

2026-09-02: Stopped at the first device gate. Enabling logging set the requested properties, but logging status remained false and no timestamped ring grew. Restore succeeded. See `map.md` for the measured state. Resume after a reboot or after the on-device Verbose Vendor Logging toggle demonstrably starts a new ring. The stale-file attempt did confirm SCAT's FIFO logger path; it did not produce live UDP packets, so latency and `--airplane` remain untested.

After reboot, the timestamped session ring grew by 4.9 MB in four seconds. The script's guard was observing the separate power-on artifact and missed the burst; the selector and timing are corrected. Another reboot is required before completing the live UDP and `--airplane` checks because this device did not start a second logging session.

2026-09-02, after the third reboot: closed. Three defects stood between the script and a live stream, all of them found on the device rather than by reading the code.

`tail -f` never returns on a ring that stopped growing, so the stream stayed pinned to the ring it started on; packets stopped roughly ten seconds after the first rotation. The remote tail now runs in the background and is swapped for the newer session, reading it from byte 0 so the rotation gap is not lost. `cleanup` blocked in `wait` on a child that ignored the signal and never restored logging. Killing `adb exec-out` on the host left the on-device `tail` running — five had accumulated across earlier attempts. The startup growth guard also rejected a healthy device, because under a nine-second rotation interval the newest ring is replaced before it is ever seen to grow in place.

Proof run with `--airplane`: 144 GSMTAP packets on `127.0.0.1:4729` over 100 seconds, SCAT attached to `/data/vendor/slog/sbuff_20260902063215.sdm` and following its rotations. Ctrl-C restored `persist.vendor.verbose_logging_enabled` to false and left no remote tails and no host processes. A default run without `--airplane` produced traffic just as well, so no radio poke is required.

Two things to know before the next run. The phone allows about one logging session per boot: after `start modem_logging_stop`, no `start modem_logging_start` brings it back and `vendor.sys.modem.logging.status` stays false until a reboot. And SCAT emits GSMTAPv3 for 5G NR, which Wireshark 4.7.2 here cannot dissect — it shows those as `Unknown GSMTAP version (3)`, so the filter now leads with bare `gsmtap`. LTE still dissects as `lte_rrc`/`nas-eps`.

## Answer

`scripts/live_tail_ring.sh` streams radio 0 as GSMTAP on `127.0.0.1:4729` until Ctrl-C. `--airplane` is optional. Stop restores logging and reaps remote tails.

Proof (2026-09-02): 144 UDP packets in 100 s while following `/data/vendor/slog/sbuff_20260902063215.sdm` across rotations. Offline decode of that same ring is 40 GSMTAP frames: NR RRC on UL/DL DCCH, CCCH, BCCH, plus NAS-5GS. A neighbouring ring (`sbuff_20260902062550.sdm`) still has an LTE MIB that this Wireshark can dissect. Both pcaps sit in `captures/ticket01/` (gitignored).

Latency in `map.md` is 2.75 s from SCAT attach to the first GSMTAP line, then bursts every 5.5–6.6 s with the rotation cadence. That is not a per-radio-event stamp. The first SDM record of the proof ring is a mid-packet join; SCAT logs one magic mismatch and resyncs.

One live session per boot. Reboot before the next run.
