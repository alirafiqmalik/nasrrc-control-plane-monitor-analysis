# Agent instructions

Shannon Pixel **NAS/RRC** monitor. Default: live stream until the user stops. Working code is `scripts/` and `src/nasrrc/`. `baseband-attach/` is a frozen prior capture.

Raw `.sdm` / `.pcap` hold subscriber identities — they stay untracked.

## Hard rule

Keep this repo simple, minimal, and easy to use. See `.scratch/adr/0001-keep-it-simple.md`. Do not add eSIM enable/disable. Airplane mode is opt-in (`--airplane`), never the default.

Commit each finished piece of work locally so progress is traceable. See `.cursor/rules/local-git.mdc`.

## Agent skills

### Issue tracker

Issues live as markdown files under `.scratch/<feature>/`. See `.scratch/agents/issue-tracker.md`.

### Triage labels

Default triage roles, labels equal to their names: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `.scratch/agents/triage-labels.md`.

### Domain docs

Single-context. ADRs live in `.scratch/adr/`. See `.scratch/agents/domain.md`.

## Capture path

`dmd` on the phone owns `/dev/umts_dm0`, but it does not own it exclusively: the node mirrors the same live SDM stream to a second reader, so a read-only tap runs alongside dmd (ticket 03). Live host decode is `scripts/live_tail_ring.sh` until Ctrl-C; `scripts/experiment_scat_diag.sh node` is the lower-latency tap, still on trial (ticket 04).

SCAT `-a` is USB bus:address; GSMTAP host is `-H`. A dump filename must contain `.sdm` so SCAT uses the logger parser (`run_logger`); `.sdmraw`, or any other name, gets the raw SDM parser (`run_diag`), which is what the DM node emits.

Device-bound work is planned in `.scratch/live-analyzer/` rather than guessed against a disconnected phone.
