# Live NAS/RRC analysis — handoff

Goal: turn the offline SDM capture pipeline into a live analyzer, MobileInsight-style,
for a Shannon-modem Pixel. This logs the research and the concrete build plan.

## Where we are

- Device: rooted Pixel 7a (lynx), Tensor GS201 = **Samsung Exynos Modem 5300 (Shannon,
  `g5300q`)**. Not Qualcomm.
- Working offline pipeline (committed `fc48c74`, `scripts/`):
  `dmd streams /dev/umts_dm0 -> .sdm -> SCAT (-t sec -L nas,rrc) -> GSMTAP pcap -> tshark`.
- Modem logging enable: `persist.vendor.verbose_logging_enabled=true` starts `dmd`
  (the on-device "Verbose Vendor Logging" toggle, or the diagnostics app, sets it).

## Why MobileInsight is not an option here

MobileInsight's `dm_collector_c` speaks **Qualcomm DIAG** (`/dev/diag`, DIAG log-config
commands). It is Qualcomm-only and needs root. The Pixel's Shannon modem uses the SDM
format, not DIAG, so MobileInsight cannot capture on this device. SCAT (`-t sec`) is the
Shannon equivalent. MobileInsight's edge is not the logging — it is the real-time
event-driven **analyzers** (`RrcAnalyzer`, `LteNasAnalyzer`, `HandoverAnalyzer`,
`MobilityMngt`). Those consume Qualcomm-DIAG-formatted messages internally, so the code is
not reusable on SCAT output — port the logic, not the code.

## Scope: what this replicates, and what it does not

Be precise about the claim. Building the analyzers you need is a few days. Replicating
**MobileInsight in full is not** — that is years of work, and the decoder is the small part.

This SCAT + tshark approach fully covers **one slice**: capturing and decoding NAS/RRC
control-plane messages. For that slice it equals or beats MobileInsight (Wireshark's
cellular dissectors are excellent). It does NOT cheaply give you:

- MobileInsight's **library of dozens of analyzers** with cross-message state machines
  (session tracking, RRC<->NAS correlation, handover-cause and reselection logic).
- **Lower-layer metrics** DIAG exposes that the RRC/NAS GSMTAP stream does not: PHY/MAC/RLC,
  per-RB RSRP, scheduling, packet KPIs. Several analyzers depend on these.
- The **real-time on-device app + callback API** other apps subscribe to.
- Breadth across RATs/vendors and years of protocol edge-case handling.

So the realistic goal here is "the 2-3 mobility analyzers the research needs", not parity.

## Why MobileInsight is built differently (not a mistake to copy)

1. History. It started ~2014-2016, before mature Shannon-capable SCAT and today's tshark
   cellular dissectors existed — they had to write their own collector and decoders. This
   SCAT-based style is only easy now because SCAT exists.
2. Qualcomm DIAG was the right target then: widest device coverage, fine-grained log-code
   control, and access to low-level metrics the SDM/GSMTAP path does not surface cleanly.
3. Real-time on-device analyzers feeding other apps was the goal; spawning tshark/pyshark
   per packet is too heavy for that, so they wrote a tight C collector + Python analyzers.
4. The analyzers and framework are the contribution; the decoder is interchangeable.

Note the ecosystem did move toward this style: SCAT (same research community, fgsect) is
the collector+decoder done properly and later, Shannon included. Pairing SCAT with a few
thin analyzers is a legitimate modern approach, not a reinvention.

## The enabling fact

SCAT is live-capable. It attaches to a live diag source and emits **GSMTAP over UDP**
(`-a <addr>`, default `127.0.0.1:4729`) — the port Wireshark auto-listens on. The decode
half is already real-time; the offline scripts just point it at a saved `.sdm`.

## Tier 1 — live packet view (hours)

```bash
scat -t sec -s /dev/umts_dm0 -a 127.0.0.1 -L nas,rrc     # GSMTAP live to :4729
wireshark -k -i lo -Y 'lte-rrc || nas-eps || nr-rrc'     # or: tshark -i lo -Y ...
```

Result: a live NAS/RRC stream — MobileInsight-grade visibility, no analyzers yet.

## The real obstacle: dmd owns the diag channel

`dmd` holds `/dev/umts_dm0` exclusively. SCAT cannot open it while dmd is running (proven
in the capture session). Two ways around it:

1. **Tail the ring (least invasive, near-live, ~seconds latency).** dmd already writes
   growing `sbuff_*.sdm` under `/data/vendor/radio/logs/always-on/`. A loop decodes the new
   bytes every 2-3 s and feeds the analyzer. Sidesteps the ownership fight. Recommended
   first path. Open question: SCAT wants a whole dump — confirm it accepts a FIFO/stdin or
   incremental file, else re-decode the growing file and de-dup by frame.
2. **Let SCAT own the port (true real-time).** Stop dmd, run
   `scat -t sec -s /dev/umts_dm0 ...` directly. Cleanest stream, but replaces Samsung's
   logger and dmd may respawn (it is not a normal init service — `stop dmd` failed). Needs
   testing; may need to block dmd's launcher.

Getting a reliable live diag handle on Shannon is the actual work — the decoding is solved.

## Tier 2 — live analysis / the analyzers (days, incremental)

Replace `tshark -r file` with a live consumer and add event logic:

```python
import pyshark
cap = pyshark.LiveCapture(interface='lo', bpf_filter='udp port 4729')
for pkt in cap.sniff_continuously():
    # mobility events to hand-code (fields tshark already dissects):
    #  handover     -> lte-rrc RRCConnectionReconfiguration w/ mobilityControlInfo
    #                  (targetPhysCellId, handover cause)
    #  measurement  -> MeasurementReport (measId, rsrp/rsrq, event A3/B1)
    #  reselection  -> SIB3/4/5 thresholds + cellReselection params
    #  NAS mobility -> TAU Request/Accept, Attach/Registration Request
    #  5G           -> nr-rrc measNo, NR reconfig, 5GMM Registration
    ...
```

Start with the 2-3 events the research needs; grow from there. Each is a small field
parser over dissected packets.

## Recommended build order

1. Tier 1 live view (an afternoon) — confirms SCAT live GSMTAP works on this device.
2. Tier 2 via the **tail-the-ring** loop feeding a pyshark analyzer for handover +
   measurement events — avoids the dmd fight, ~90% of the value.
3. Grow analyzers only for events the research needs. Full MobileInsight parity is a long
   tail and rarely necessary.

## Open questions to resolve

- Does SCAT accept a streaming input (FIFO/stdin) for the tail-the-ring path, or must it
  re-read a growing file? Test with a small `sbuff` slice.
- Can SCAT own `/dev/umts_dm0` if dmd is suspended, and does dmd respawn? Test in a
  throwaway window; keep a way to restore logging.
- Latency of the tail-the-ring loop vs dmd's flush cadence — measure the sbuff write
  interval under load.
- 5G: none of this changes for NR, but a live NR capture still needs actual NR coverage
  (the Pixel stayed on LTE+CA; see `../nonroot-rsp-capture` and the 4G-vs-5G notes).

## References

- Offline scripts: `scripts/capture_nas_rrc.sh`, `scripts/decode_nas_rrc.sh`, `scripts/README.md`.
- Decoded LTE example: `scripts/example-lte/`.
- SCAT: fgsect/scat (PyPI `signalcat`), Samsung path `-t sec`, Qualcomm `-t qc`.
- MobileInsight: github.com/mobile-insight/mobileinsight-core (Qualcomm DIAG; reference for
  analyzer event logic only).
