# Map — live-analyzer

## Notes

- Offline capture/decode scripts lifted from `baseband-attach/scripts/` and pointed at a local `.venv`.
- Summary-line classifier in `src/nasrrc/` proven against `fixtures/example-lte/LTE_full_summary.txt`.
- Live host path is **tail the ring over adb**, not `scat -s /dev/umts_dm0` on the host.

## Decisions-so-far

- GSMTAP host flag is `-H`, not `-a`.
- Dump name must contain `.sdm` for the logger parser.
- First live implementation: FIFO + `adb exec-out tail -f sbuff_*.sdm`. Device proof is ticket 01.
- Default run is continuous until Ctrl-C. `--airplane` is optional. No eSIM on/off.
- Keep the repo simple (ADR-0001).
- Handover vs generic reconfiguration is deferred to dissected-field analyzers (ticket 02).

## Fog

- Does `tail -f` over adb keep SDM framing intact (no split packets / mid-file header)?
- Latency of dmd flush vs the tail loop.
- Can SCAT own `/dev/umts_dm0` if dmd is blocked, and how to restore logging.
- USB `-u` SDM on this Pixel (Samsung start-magic) — untested.
- NR: same pipeline, but the 2026-08-13 capture stayed LTE+CA.
