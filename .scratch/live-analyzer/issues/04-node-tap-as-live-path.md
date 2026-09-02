# 04 — Fold the DM node tap into the live path

**What to build:** Make `scripts/experiment_scat_diag.sh node` the live path —
either by teaching `scripts/live_tail_ring.sh` to read `/dev/umts_dm0` directly
or by replacing it — once the tap is shown to survive a long run.

**Blocked by:** None. Ticket 03 proved the mechanism; this is about trusting it.

**Status:** ready-for-agent

Ticket 03 found that `/dev/umts_dm0` mirrors the live SDM stream to a second
reader while dmd keeps logging. That removes the ring rotation follower, the
`start modem_logging_start` nudging, the rotation-splice resync and the ~30 s
flush cadence in one move — most of `live_tail_ring.sh`.

Do not delete the ring path before this is settled. What is still unproven:

- [ ] A run of an hour or more without the tap dying or the phone slowing down
- [ ] Behaviour across an airplane cycle (`--airplane`) and a modem crash
- [ ] Whether frames are ever dropped between two `cat` invocations of the loop —
      compare a node capture against the ring for the same window
- [ ] Whether `sbuff_power_on_log.sdm` still hides the first seconds after boot
- [ ] Whether the tap needs modem logging enabled at all, or only a DM session

If it holds, `live_tail_ring.sh` becomes a fallback rather than the default, and
`README.md` and `AGENTS.md` need the capture-path paragraph rewritten again.
