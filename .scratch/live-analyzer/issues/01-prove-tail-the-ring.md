# 01 — Prove tail-the-ring GSMTAP on the Pixel

**What to build:** With the phone USB-connected and rooted, `scripts/live_tail_ring.sh` streams NAS/RRC GSMTAP on UDP 4729 until Ctrl-C. Restore logging props on stop.

**Blocked by:** None — can start immediately (script exists; this is the device proof).

**Status:** ready-for-agent

- [ ] Verbose vendor logging actually produces a growing `sbuff_*.sdm`
- [ ] SCAT on the host parses the FIFO (logger path) without treating it as raw SDM
- [ ] tshark on `lo` udp/4729 shows NAS/RRC while the stream runs (no radio poke required)
- [ ] `--airplane` is optional and a subsequent Ctrl-C still restores logging
- [ ] Note measured latency (dmd flush → tshark line) in `map.md`

## Comments
Follow `.scratch/live-analyzer/plan-device-live.md`. Do not open `/dev/umts_dm0` from the host. Do not toggle eSIM.
