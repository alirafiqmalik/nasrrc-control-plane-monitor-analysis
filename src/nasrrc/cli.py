from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections import Counter
from collections.abc import Iterable, Iterator
from pathlib import Path

from nasrrc.events import Event, classify_summary_file, classify_summary_lines
from nasrrc.fields import GSMTAP_PORT, FieldEvent, analyze_interface, analyze_pcap


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="nasrrc",
        description="Classify NAS/RRC events from a tshark summary, a GSMTAP pcap, or a live stream.",
    )
    parser.add_argument("input", type=Path, nargs="?", help="cap.summary.txt or cap.pcap")
    parser.add_argument(
        "-i",
        "--interface",
        help="read live GSMTAP from this interface instead of a file (implies --fields)",
    )
    parser.add_argument("--port", type=int, default=GSMTAP_PORT, help="GSMTAP UDP port")
    parser.add_argument("--host", help="only accept GSMTAP sent to this address (radio 0)")
    parser.add_argument(
        "--fields",
        action="store_true",
        help="analyze dissected fields: measId, RSRP/RSRQ, real handovers",
    )
    parser.add_argument("--kinds", action="store_true", help="print kind counts only")
    parser.add_argument("--json", action="store_true", help="print one JSON object per event")
    args = parser.parse_args(argv)

    if args.interface:
        events = analyze_interface(args.interface, port=args.port, host=args.host)
    elif args.input is None:
        parser.error("give an input file or --interface")
    elif not args.input.exists():
        print(f"not found: {args.input}", file=sys.stderr)
        return 1
    elif args.fields:
        # A FIFO carrying a pcap stream is fine too: that is the no-phone replay path.
        if args.input.suffix not in {".pcap", ".pcapng"} and args.input.is_file():
            print("--fields needs a pcap; summaries carry no dissected fields", file=sys.stderr)
            return 1
        events = analyze_pcap(args.input)
    elif args.input.suffix in {".pcap", ".pcapng"}:
        events = iter(_from_pcap(args.input))
    else:
        events = iter(classify_summary_file(args.input))

    try:
        return _emit(events, kinds=args.kinds, as_json=args.json)
    except KeyboardInterrupt:
        return 0
    except RuntimeError as exc:
        print(exc, file=sys.stderr)
        return 1
    except BrokenPipeError:
        # Downstream `head` or similar closed the pipe; that is a normal stop.
        sys.stdout = None
        return 0
    finally:
        close = getattr(events, "close", None)
        if close is not None:
            close()


def _emit(events: Iterable[Event | FieldEvent], *, kinds: bool, as_json: bool) -> int:
    if kinds:
        counts = Counter(ev.kind for ev in events)
        for kind, n in counts.most_common():
            print(f"{n:5d}  {kind}")
        return 0

    for ev in events:
        if as_json:
            print(json.dumps(_as_dict(ev)), flush=True)
        else:
            print(_format_event(ev), flush=True)
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


def _as_dict(ev: Event | FieldEvent) -> dict:
    if isinstance(ev, FieldEvent):
        return ev.as_dict()
    return {
        "frame": ev.frame,
        "t_rel": ev.t_rel,
        "protocol": ev.protocol,
        "kind": ev.kind,
        "info": ev.info,
    }


def _format_event(ev: Event | FieldEvent) -> str:
    if isinstance(ev, FieldEvent):
        return f"{ev.frame:6d}  {ev.t_rel:12.6f}  {ev.kind:<28}  {ev.rat:<3}  {ev.describe()}"
    return f"{ev.frame}\t{ev.t_rel:.6f}\t{ev.kind}\t{ev.info}"


if __name__ == "__main__":
    raise SystemExit(main())
