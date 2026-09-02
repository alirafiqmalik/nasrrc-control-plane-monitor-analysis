# 01 — Prove tail-the-ring GSMTAP on the Pixel

**What to build:** With the phone USB-connected and rooted, `scripts/live_tail_ring.sh` streams NAS/RRC GSMTAP on UDP 4729 until Ctrl-C. Restore logging props on stop.

**Blocked by:** None — can start immediately (script exists; this is the device proof).

**Status:** needs-info

- [x] Verbose vendor logging actually produces a growing `sbuff_*.sdm`
- [x] SCAT on the host parses the FIFO (logger path) without treating it as raw SDM
- [ ] tshark on `lo` udp/4729 shows NAS/RRC while the stream runs (no radio poke required)
- [ ] `--airplane` is optional and a subsequent Ctrl-C still restores logging
- [ ] Note measured latency (dmd flush → tshark line) in `map.md`

## Comments
Follow `.scratch/live-analyzer/plan-device-live.md`. Do not open `/dev/umts_dm0` from the host. Do not toggle eSIM.

2026-09-02: Stopped at the first device gate. Enabling logging set the requested properties, but logging status remained false and no timestamped ring grew. Restore succeeded. See `map.md` for the measured state. Resume after a reboot or after the on-device Verbose Vendor Logging toggle demonstrably starts a new ring. The stale-file attempt did confirm SCAT's FIFO logger path; it did not produce live UDP packets, so latency and `--airplane` remain untested.

After reboot, the timestamped session ring grew by 4.9 MB in four seconds. The script's guard was observing the separate power-on artifact and missed the burst; the selector and timing are corrected. Another reboot is required before completing the live UDP and `--airplane` checks because this device did not start a second logging session.
