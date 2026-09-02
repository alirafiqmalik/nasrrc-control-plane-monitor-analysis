#!/usr/bin/env bash
# Print GSMTAP pcaps as plain text. Default: every *.pcap under captures/.
# Usage: ./dump_pcap.sh [pcap-or-dir ...] [-v]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

need_cmd tshark

VERBOSE=0
TARGETS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose)
      VERBOSE=1
      shift
      ;;
    -h|--help)
      echo "Usage: $(basename "$0") [pcap-or-dir ...] [-v]"
      echo "  one-line tshark summary per frame (Protocol + Info)."
      echo "  -v  full dissection (-V). Default path: captures/"
      exit 0
      ;;
    -*)
      echo "unknown argument: $1" >&2
      exit 1
      ;;
    *)
      TARGETS+=("$1")
      shift
      ;;
  esac
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  TARGETS=("$NASRRC_ROOT/captures")
fi

label() {
  local f="$1"
  if [[ "$f" == "$NASRRC_ROOT"/* ]]; then
    printf '%s\n' "${f#"$NASRRC_ROOT"/}"
  else
    printf '%s\n' "$f"
  fi
}

collect() {
  local t="$1"
  if [[ -d "$t" ]]; then
    find "$t" -type f \( -name '*.pcap' -o -name '*.pcapng' \) | sort
  elif [[ -e "$t" ]]; then
    printf '%s\n' "$t"
  else
    echo "not found: $t" >&2
    return 1
  fi
}

dump_one() {
  local f="$1"
  echo "=== $(label "$f") ==="
  if [[ ! -s "$f" ]]; then
    echo "(empty)"
    echo
    return 0
  fi
  if [[ "$VERBOSE" -eq 1 ]]; then
    tshark -r "$f" -V
  else
    tshark -r "$f" -T fields -e frame.number -e frame.time_relative \
      -e _ws.col.Protocol -e _ws.col.Info
  fi
  echo
}

FOUND=0
for target in "${TARGETS[@]}"; do
  while IFS= read -r pcap; do
    [[ -n "$pcap" ]] || continue
    dump_one "$pcap"
    FOUND=1
  done < <(collect "$target")
done

if [[ "$FOUND" -eq 0 ]]; then
  echo "no .pcap under ${TARGETS[*]}" >&2
  exit 1
fi
