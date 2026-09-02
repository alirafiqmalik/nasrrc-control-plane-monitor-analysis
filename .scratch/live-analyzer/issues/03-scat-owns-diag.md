# 03 — Experiment: SCAT owns /dev/umts_dm0

**What to build:** A throwaway, reversible test of whether SCAT can run on-device (or via USB DM `-u`) against `/dev/umts_dm0` after suspending `dmd`, plus a documented restore path. True realtime is the prize; do not replace the tail-the-ring path unless this is reliable.

**Blocked by:** None — isolated experiment. Keep 01 working regardless of outcome.

**Status:** ready-for-human

- [ ] Record how `dmd` is started (not a normal `stop dmd` service)
- [ ] Attempt SCAT serial on the phone with a restore script ready
- [ ] If USB DM works on this Pixel, document vendor/product/interface and start-magic
- [ ] Write the result into `map.md` (works / respawns / bricks logging until reboot)

## Comments
Host `scat -s /dev/umts_dm0` cannot work: that node is on the Pixel. See `plan-device-live.md`.
