# Spec — live NAS/RRC analyzer (Shannon Pixel)

Host-side live NAS/RRC stream for a Shannon-modem Pixel, running until the user
stops it. Decoder is SCAT; the product is GSMTAP plus a few mobility events, not
MobileInsight parity. No eSIM toggling. Airplane mode is optional (`--airplane`).

## Device facts

- Rooted Pixel 7a (lynx), Tensor GS201 = Samsung Exynos Modem 5300 (`g5300q`).
- Diagnostic format is SDM, not Qualcomm DIAG. SCAT `-t sec`.
- `dmd` holds `/dev/umts_dm0`, but not exclusively: the node mirrors its stream to a second reader (ticket 03). A read-only tap over adb feeds SCAT the raw SDM directly; the host still cannot open the node itself.
- Active session ring: timestamped `sbuff_[0-9]*.sdm` under `/data/vendor/slog/`, rotated into `/data/vendor/radio/logs/always-on/`. `sbuff_power_on_log.sdm` and `sbuff_profile.sdm` are separate artifacts.
- Enable logging: `persist.vendor.verbose_logging_enabled=true` (plus the shannon/modem logging props the capture script sets).

## Pipeline

```
dmd on phone → sbuff_*.sdm → adb stream → host SCAT (-t sec -d *.sdm)
                                         → GSMTAP UDP :4729
                                         → tshark / nasrrc classifier
```

Offline variant writes a pcap (`-F`) instead of UDP.

## SCAT gotchas (verified in signalcat 2.0 FileIO / SamsungParser)

- `-H` / `-P` select GSMTAP host/port. `-a` is USB bus:address, not an IP.
- Filename containing `.sdm` → `run_logger` (always-on logger wrapping). Anything else (including `/dev/stdin`) → raw SDM `run_diag`.
- FileIO sets `block_until_data=False`, so a regular file is read once to EOF. A FIFO stays open while the writer (`tail -f`) lives, which is the intended live dump path.
- Serial `-s` against the DM node is a dead end (ticket 03). `init_diag` reaches the modem and the modem does not answer: dmd starts the DM session over the vendor RIL path, not by writing SDM control frames. Read the node instead — `-d <fifo>.sdmraw` — and let dmd keep its session.

## Events (first cut)

Classify from tshark Info strings: attach, identity, ESM info, RRC SMC,
RRC setup, RRC reconfiguration, measurement report, TAU, 5G registration.

RRCConnectionReconfiguration is **not** a handover by itself. Handover needs
`mobilityControlInfo` (or NR equivalent) from a verbose/field decode — that is
the pyshark analyzer ticket, not the summary classifier.

## Non-goals

- MobileInsight analyzer library / on-device app / DIAG PHY KPIs.
- Qualcomm devices (`-t qc`).
- Committing raw dumps.
- eSIM enable/disable as a capture driver.
- Required airplane-mode cycles (opt-in `--airplane` only).
