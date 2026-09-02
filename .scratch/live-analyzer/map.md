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
- 2026-09-02 device proof stopped at the first gate: both modem logging enable properties became `true`, but `vendor.sys.modem.logging.status` stayed `false`, no `dmd` process opened `/dev/umts_dm0`, and the newest timestamped ring (`/data/vendor/radio/logs/always-on/sbuff_20260901230105.sdm`) remained at 6,016,827 bytes with a 2026-09-01 23:01:09 mtime. Android init showed the logging-control services running; the kernel reported that `umts_dm0` was not open. The props were restored to `false`. A reboot or a successful on-device Verbose Vendor Logging toggle is needed before the remaining proof can run.
- The same attempt confirmed that a FIFO named `.sdm` enters SCAT's logger path (`read_dump` → `run_logger`), rather than raw SDM. It decoded the stale `sbuff_power_on_log.sdm`, but that does not prove live delivery. Host tshark needs `lte_rrc` (underscore) on this installation and needs elevated capture permission. Latency and startup-frame integrity (truncation or garbling) are not measurable until the ring grows.
- After the reboot, verbose logging created `/data/vendor/slog/sbuff_20260902035852.sdm`; it grew from 0 to 4,853,568 bytes between 03:58:52 and 03:58:56 before rotating into `always-on`. The first post-reboot script run missed this burst because it waited three seconds and watched the newer `sbuff_power_on_log.sdm`; the selector now starts immediately and excludes the power-on/profile artifacts. A further reboot is needed to exercise the corrected live path because later enable attempts did not start another session.

## Fog

- Does `tail -f` over adb keep SDM framing intact (no split packets / mid-file header) once device logging starts again?
- Latency of dmd flush vs the tail loop (unavailable in the 2026-09-02 attempt because the ring did not grow).
- Can SCAT own `/dev/umts_dm0` if dmd is blocked, and how to restore logging.
- USB `-u` SDM on this Pixel (Samsung start-magic) — untested.
- NR: same pipeline, but the 2026-08-13 capture stayed LTE+CA.
