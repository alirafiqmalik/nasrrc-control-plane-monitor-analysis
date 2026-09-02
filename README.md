# NAS/RRC control-plane monitor

Live NAS/RRC for a rooted Shannon-modem Pixel. Stream until you stop it.

```bash
./scripts/setup_venv.sh          # once: adb, tshark, rooted Pixel
./scripts/live_tail_ring.sh      # Ctrl-C to stop
# optional: ./scripts/live_tail_ring.sh --airplane
```

Listen in another terminal:

```bash
tshark -i lo -f 'udp port 4729' -Y 'lte-rrc || nas-eps || nr-rrc || nas-5gs'
```

Use `.venv/bin/python` for `nasrrc` and SCAT. Snapshot a dump with `scripts/capture_nas_rrc.sh [outdir] [--airplane]`, then `scripts/decode_nas_rrc.sh`. Classify: `.venv/bin/python -m nasrrc --kinds fixtures/example-lte/LTE_full_summary.txt`.

`dmd` owns `/dev/umts_dm0` on the phone; host SCAT reads `sbuff_*.sdm` over adb. GSMTAP host is `-H` (not `-a`). Dump names must contain `.sdm`. Raw `.sdm`/`.pcap` are gitignored (subscriber identities). `baseband-attach/` is the frozen 2026-08-13 capture.
