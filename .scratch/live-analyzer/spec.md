# Spec — live NAS/RRC analyzer (Shannon Pixel)

Host-side live NAS/RRC stream for a Shannon-modem Pixel, running until the user
stops it. Decoder is SCAT; the product is GSMTAP plus a few mobility events, not
MobileInsight parity. No eSIM toggling. Airplane mode is optional (`--airplane`).

## Device facts

- Rooted Pixel 7a (lynx), Tensor GS201 = Samsung Exynos Modem 5300 (`g5300q`).
- Diagnostic format is SDM, not Qualcomm DIAG. SCAT `-t sec`.
- `dmd` holds `/dev/umts_dm0` exclusively. Host SCAT cannot open that node.
- Always-on ring: `/data/vendor/radio/logs/always-on/sbuff_*.sdm` (also `/data/vendor/slog/`).
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
- Serial `-s /dev/umts_dm0` is the on-device true-realtime path. It also runs `init_diag` and fights `dmd`. That experiment is a later ticket, on the phone or via USB DM, not a host open of the char node.

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
