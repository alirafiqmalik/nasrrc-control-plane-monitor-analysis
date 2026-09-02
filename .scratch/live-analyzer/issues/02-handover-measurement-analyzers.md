# 02 — Handover and measurement analyzers on dissected fields

**What to build:** From a live or replayed GSMTAP stream (or a pcap), emit structured events for measurement reports (measId, RSRP/RSRQ, A3/B1) and true handovers (`mobilityControlInfo` / NR equivalent), not every RRCConnectionReconfiguration.

**Blocked by:** None for offline pcap work. Live demo waits on 01.

**Status:** resolved

- [x] Replay path `live_replay_sdm.sh` feeds the analyzer without a phone
- [x] Measurement events include measId and the reported quantity when tshark exposes it
- [x] Reconfiguration without mobilityControlInfo is not labelled handover
- [x] NAS attach/TAU/identity keep working from the summary classifier or the same consumer

## Comments
Summary-line classification in `src/nasrrc/` is the baseline. This ticket adds a tshark-field or pyshark consumer. Full MobileInsight parity is out of scope.

2026-09-02: ticket 01 is resolved. Offline sample pcaps from that proof are in `captures/ticket01/` (gitignored). NR arrives as GSMTAPv3, so field analyzers that need dissected NR still wait on a v3-aware Wireshark. LTE MIB from the same session does dissect.

2026-09-02, closing. Three things decided the shape of this.

`-T fields` cannot do it. The measurement report says `measId`, but which reporting event that measId belongs to is configured in an *earlier* `RRCConnectionReconfiguration`, and in flat field output `lte-rrc.reportConfigId` occurs once per `ReportConfigToAddMod` and again once per `MeasIdToAddMod`. Occurrence order cannot separate the two lists, so the A3/B1 label is unrecoverable. PDML keeps the nesting, still streams packet by packet under `-l`, and needs nothing beyond the standard library to parse — so the same parser serves a pcap, a FIFO, and a live interface.

There was no capture to develop against. Real dumps are untracked by policy and none is on this host. `fixtures/synthetic-lte/make_pcap.py` hand-encodes the UPER: a measConfig binding measId 1 to eventA3 and measId 2 to eventB1, a measurement report with a serving cell and two neighbours, a handover command carrying `mobilityControlInfo`, a reconfiguration carrying neither, plus NAS attach and identity. tshark dissects all twelve frames with no expert warning. One deviation from the published grammar cost some time: Wireshark's `MeasResults` has two root optional bits before `measId`, and only the second gates `measResultNeighCells`.

The live demo cannot run on this host. `/usr/bin/dumpcap` is `root:wireshark` 0754 and the user is not in `wireshark`, so `tshark -i lo` fails with "Couldn't run dumpcap in child process: Permission denied" — for a named pipe as well as a real interface. `tshark -r <fifo>` skips dumpcap entirely and still streams as the writer writes, so `live_replay_sdm.sh --analyze` hands SCAT `-F <fifo>` and reads that, and the no-phone path needs no privileges at all. Interface capture is still there (`live_analyze.sh lo`) for a host that has the rights.

## Answer

`src/nasrrc/fields.py` turns dissected packets into mobility events; `scripts/live_analyze.sh` is the consumer and takes an interface, a pcap, or a FIFO. Live capture needs `dumpcap` rights; the file and FIFO paths do not.

```
     4      0.300000  tau_request                   lte  Tracking area update request
     5      0.400000  rrc_reconfiguration           lte  rrcConnectionReconfiguration | configures measId1=a3
     6      0.500000  rrc_reconfiguration           lte  rrcConnectionReconfiguration | configures measId2=b1
     7      0.600000  rrc_reconfiguration           lte  rrcConnectionReconfiguration
     9      0.800000  measurement_report            lte  measurementReport | measId=1 trigger=a3 | serving rsrp=-79dBm rsrq=-8dB | neighbour=pci250 rsrp=-70dBm rsrq=-6.5dB | neighbour=pci301 rsrp=-86dBm rsrq=-11dB
    11      1.000000  handover                      lte  rrcConnectionReconfiguration | target=pci250
```

Frames 5, 6 and 7 are reconfigurations and stay `rrc_reconfiguration`; only frame 11 carries `mobilityControlInfo` and only it is called a handover. `Analyzer` holds the measId → event map across packets, so frame 9 is labelled `a3` from what frame 5 configured, and `measIdToRemoveList` drops the entry again. NAS keeps working through the same consumer: the analyzer feeds the dissected EMM/ESM message type into `nasrrc.events.kind_for_info`, the same rules the summary classifier uses, so attach, TAU and identity land on the same kind strings either way. `--json` prints one object per event. Broadcast and paging are dropped, as in the summary classifier.

### Device run, 2026-09-02

Run on the Pixel 7a, both paths. `live_replay_sdm.sh --analyze` against a 52 MB ring pulled off the phone, and `live_tail_ring.sh` live for nine minutes with a plain UDP socket on `127.0.0.1:4729` standing in for tshark, which cannot capture on this host.

425 GSMTAP packets, 81 events: 63 measurement reports, 9 reconfigurations, 9 completes, zero handovers — right for a stationary UE. The correlation this ticket exists for works against a live network:

```
    59  49.383299  rrc_reconfiguration  lte  configures measId26=a1,measId27=a2,measId28=a5,measId29=a5
    63  53.400818  measurement_report   nr   measId=26 trigger=a1 | serving=pci799 servCell=7 rsrp=-112dBm rsrq=-11.5dB sinr=10.5dB | serving=pci799 servCell=8 rsrp=-119dBm rsrq=-12dB sinr=6dB
```

The network re-issues that NR config about once a minute and the next report comes back tagged. LTE `measId=5` was configured before the capture opened and correctly carries no trigger.

Three things the device corrected. NR was not unproven after all — this Wireshark dissects the NR RRC SCAT emits in a normal session, and only the ticket-01 proof ring was v3. A real EN-DC report carries two `MeasResultServMO` entries for the same PSCell, so the analyzer reports every serving MO tagged with its servCellId instead of the first. And NR spells the quantities `measQuantityResults.rsrp` / `.rsrq` / `.sinr`, not `rsrp-Result`; with that fixed the 38.133 conversions match Wireshark's own labels exactly (rsrp 43 → -114 dBm, rsrq 63 → -12.0 dB, sinr 64 → 8.5 dB), and the LTE conversion agrees with SCAT's PHY log for the same serving cell.

Still open: no handover has been captured, because the UE has not moved. `mobilityControlInfo` and `reconfigurationWithSync` remain exercised only against the synthetic fixture.
