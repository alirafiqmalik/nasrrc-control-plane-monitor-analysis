# 02 — Handover and measurement analyzers on dissected fields

**What to build:** From a live or replayed GSMTAP stream (or a pcap), emit structured events for measurement reports (measId, RSRP/RSRQ, A3/B1) and true handovers (`mobilityControlInfo` / NR equivalent), not every RRCConnectionReconfiguration.

**Blocked by:** None for offline pcap work. Live demo waits on 01.

**Status:** ready-for-agent

- [ ] Replay path `live_replay_sdm.sh` feeds the analyzer without a phone
- [ ] Measurement events include measId and the reported quantity when tshark exposes it
- [ ] Reconfiguration without mobilityControlInfo is not labelled handover
- [ ] NAS attach/TAU/identity keep working from the summary classifier or the same consumer

## Comments
Summary-line classification in `src/nasrrc/` is the baseline. This ticket adds a tshark-field or pyshark consumer. Full MobileInsight parity is out of scope.
