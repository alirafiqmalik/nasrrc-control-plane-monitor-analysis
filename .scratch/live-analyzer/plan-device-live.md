# Plan — device-bound live path

Host-side scaffolding is in `scripts/`. These steps need the rooted Pixel on USB.
Stop after the first failing step and write the result into `map.md`.

## 0. Preconditions

- `adb devices` shows the Pixel, `adb shell su -c id` is root.
- `./scripts/setup_venv.sh` has been run; `tshark` is on PATH.
- Logging restore is known: `setprop persist.vendor.verbose_logging_enabled false` and `start modem_logging_stop`.

## 1. Snapshot pull (optional)

```bash
./scripts/capture_nas_rrc.sh captures/smoke
./scripts/decode_nas_rrc.sh captures/smoke/cap.sdm
.venv/bin/python -m nasrrc --kinds captures/smoke/cap.summary.txt
```

Done when: `cap.pcap` exists. NAS may be idle if nothing is signalling — that is fine.

## 2. Replay GSMTAP from a saved dump

```bash
# terminal A
tshark -i lo -f 'udp port 4729 and dst host 127.0.0.1' -Y 'gsmtap || lte_rrc || nas-eps || nr-rrc || nas-5gs'
# terminal B
./scripts/live_replay_sdm.sh captures/smoke/cap.sdm
```

Skip if there is no dump; use `fixtures/example-lte/` for the classifier only.

## 3. Live stream until Ctrl-C (ticket 01)

```bash
./scripts/live_tail_ring.sh
# other terminal: tshark as above (use sudo if dumpcap lacks capture permission)
# optional later: ./scripts/live_tail_ring.sh --airplane
```

Record:

- Path of the `sbuff_*.sdm` that was tailed.
- Whether SCAT logs "Reading from ...sdm" (logger) vs "Unknown baseband dump type".
- Latency from a radio event to the tshark line.
- Any truncated/garbled frames at the start (logger header / mid-packet join).

If FIFO parse fails, fallback: pull the growing file every 2–3 s, decode to pcap, classify, de-dup by frame identity. That fallback is still ticket 01.

## 4. Do not run in the same window as 3: SCAT owns diag (ticket 03)

Separate throwaway session. Have a reboot as the last-resort restore.

On-device SCAT needs Python+signalcat on the Pixel or a known USB DM interface (`scat -t sec -u ... --start-magic`). Host `-s /dev/umts_dm0` is not a valid test.

## 5. Stop

Ticket 02 (handover/measurement fields) can proceed offline from a pcap. Do not start a pyshark live consumer until step 3 is green.
