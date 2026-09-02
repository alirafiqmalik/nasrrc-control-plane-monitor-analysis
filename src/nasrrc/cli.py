from __future__ import annotations

import argparse
import subprocess
import sys
from collections import Counter
from pathlib import Path

from nasrrc.events import Event, classify_summary_file, classify_summary_lines


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="nasrrc",
        description="Classify NAS/RRC events from a tshark summary or GSMTAP pcap.",
    )
    parser.add_argument("input", type=Path, help="cap.summary.txt or cap.pcap")
    parser.add_argument("--kinds", action="store_true", help="print kind counts only")
    args = parser.parse_args(argv)

    src = args.input
    if not src.exists():
        print(f"not found: {src}", file=sys.stderr)
        return 1

    if src.suffix in {".pcap", ".pcapng"}:
        events = _from_pcap(src)
    else:
        events = classify_summary_file(src)

    if args.kinds:
        counts = Counter(ev.kind for ev in events)
        for kind, n in counts.most_common():
            print(f"{n:5d}  {kind}")
        return 0

    for ev in events:
        print(_format_event(ev))
    return 0


def _from_pcap(path: Path) -> list[Event]:
    proc = subprocess.run(
        [
            "tshark",
            "-r",
            str(path),
            "-T",
            "fields",
            "-e",
            "frame.number",
            "-e",
            "frame.time_relative",
            "-e",
            "_ws.col.Protocol",
            "-e",
            "_ws.col.Info",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return classify_summary_lines(proc.stdout.splitlines())


def _format_event(ev: Event) -> str:
    return f"{ev.frame}\t{ev.t_rel:.6f}\t{ev.kind}\t{ev.info}"


if __name__ == "__main__":
    raise SystemExit(main())
