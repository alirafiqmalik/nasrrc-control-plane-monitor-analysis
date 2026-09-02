# NAS/RRC control-plane monitor

Live NAS/RRC for a rooted Shannon-modem Pixel. Stream until you stop it.

```bash
./scripts/setup_venv.sh          # once: adb, tshark, rooted Pixel
./scripts/live_tail_ring.sh      # Ctrl-C to stop
# optional: ./scripts/live_tail_ring.sh --airplane
```

Listen in another terminal:

```bash
tshark -i lo -f 'udp port 4729 and dst host 127.0.0.1' -Y 'gsmtap || lte_rrc || nas-eps || nr-rrc || nas-5gs'
```

Mobility events — measurement reports with their measId, trigger event and
RSRP/RSRQ, and handovers that really carry `mobilityControlInfo`:

```bash
./scripts/live_analyze.sh                          # capture on lo, Ctrl-C to stop
./scripts/live_analyze.sh cap.pcap                 # a saved GSMTAP pcap
./scripts/live_replay_sdm.sh --analyze cap.sdm     # replay a dump, no phone needed
```

```
     9      0.800000  measurement_report  lte  measurementReport | measId=1 trigger=a3 | serving rsrp=-79dBm rsrq=-8dB | neighbour=pci250 rsrp=-70dBm rsrq=-6.5dB
    11      1.000000  handover            lte  rrcConnectionReconfiguration | target=pci250
```

Add `--json` for one JSON object per event, `--kinds` for counts. Live capture on
an interface goes through `dumpcap`, so it needs capture rights; reading a pcap or
a FIFO does not, which is why `--analyze` replays through a FIFO.

Use `.venv/bin/python` for `nasrrc` and SCAT. Snapshot a dump with `scripts/capture_nas_rrc.sh [outdir] [--airplane]`, then `scripts/decode_nas_rrc.sh`. Classify from a summary: `.venv/bin/python -m nasrrc --kinds fixtures/example-lte/LTE_full_summary.txt`.

The phone allows about one logging session per boot: once the script has stopped and restored logging, a second run needs a reboot first.

SCAT emits **GSMTAPv3** for 5G NR. Wireshark builds without a v3 dissector show those as `Unknown GSMTAP version (3)`, so the filter keeps bare `gsmtap` — LTE still dissects as `lte_rrc`/`nas-eps`.

`dmd` owns `/dev/umts_dm0` on the phone; host SCAT reads `sbuff_*.sdm` over adb. GSMTAP host is `-H` (not `-a`). Dump names must contain `.sdm`. Raw `.sdm`/`.pcap` are gitignored (subscriber identities). `baseband-attach/` is the frozen 2026-08-13 capture. `fixtures/synthetic-lte/` is a hand-encoded GSMTAP pcap with no subscriber data, so the analyzer has something to test against.
