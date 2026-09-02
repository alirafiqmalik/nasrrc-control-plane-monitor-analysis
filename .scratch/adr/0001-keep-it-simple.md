# Keep this repo simple, minimal, and easy to use

This is a small research tool: stream Shannon NAS/RRC until the user stops it. New code, flags, docs, and tickets must earn their place against that.

**Status:** accepted

Prefer one obvious command (`scripts/live_tail_ring.sh`), few files, and default behaviour that does not poke the radio. Reject extra event drivers (eSIM enable/disable, required airplane cycles), extra frameworks, and docs that restate the scripts. If a change makes the tree harder to run or explain, it is wrong.
