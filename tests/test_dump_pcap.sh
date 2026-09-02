#!/usr/bin/env bash
# dump_pcap.sh against the synthetic fixture. No device, no subscriber dumps.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PCAP="$ROOT/fixtures/synthetic-lte/lte-mobility.pcap"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILURES=0
fail() { echo "FAIL: $1" >&2; FAILURES=$(( FAILURES + 1 )); }

DUMP="$ROOT/scripts/dump_pcap.sh"

# --- one-line fields for a known GSMTAP pcap ---------------------------------
"$DUMP" "$PCAP" > "$TMP/summary.txt" 2>"$TMP/summary.err" || fail "summary exit $? $(cat "$TMP/summary.err")"
grep -q '=== fixtures/synthetic-lte/lte-mobility.pcap ===' "$TMP/summary.txt" \
  || fail "header missing: $(head -1 "$TMP/summary.txt")"
grep -q $'1\t0.000000000\tGSMTAP/NAS-EPS\tAttach request' "$TMP/summary.txt" \
  || fail "attach request missing"
grep -q $'9\t0.800000000\tLTE RRC UL_DCCH\tMeasurementReport' "$TMP/summary.txt" \
  || fail "measurement report missing"

# --- empty pcap is a note, not a tshark error --------------------------------
: > "$TMP/empty.pcap"
"$DUMP" "$TMP/empty.pcap" > "$TMP/empty.out" 2>"$TMP/empty.err" || fail "empty pcap exit $?"
grep -q '(empty)' "$TMP/empty.out" || fail "empty pcap was not labelled empty"
[[ ! -s "$TMP/empty.err" ]] || fail "empty pcap wrote stderr: $(cat "$TMP/empty.err")"

# --- missing path fails ------------------------------------------------------
"$DUMP" "$TMP/missing.pcap" > "$TMP/missing.out" 2>"$TMP/missing.err"
[[ $? -ne 0 ]] || fail "missing pcap exited 0"
grep -q 'not found' "$TMP/missing.err" || fail "missing pcap had no explanation"

# --- directory of one pcap ---------------------------------------------------
mkdir -p "$TMP/caps"
cp "$PCAP" "$TMP/caps/one.pcap"
"$DUMP" "$TMP/caps" > "$TMP/dir.out" 2>"$TMP/dir.err" || fail "dir dump exit $?"
grep -q 'Attach request' "$TMP/dir.out" || fail "dir dump missed frames"

# --- verbose dissection still names the messages -----------------------------
"$DUMP" -v "$PCAP" > "$TMP/verbose.txt" 2>"$TMP/verbose.err" || fail "verbose exit $?"
grep -q 'Attach request' "$TMP/verbose.txt" || fail "verbose missed NAS"
grep -q 'LTE Radio Resource Control' "$TMP/verbose.txt" \
  || grep -q 'lte_rrc' "$TMP/verbose.txt" \
  || fail "verbose missed RRC tree"

if (( FAILURES )); then
  echo "$FAILURES scenario(s) failed" >&2
  exit 1
fi
echo "PASS: dump_pcap summary, empty, missing, dir, verbose"
