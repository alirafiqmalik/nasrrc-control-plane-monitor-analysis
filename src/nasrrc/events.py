from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path

# First match wins. More specific strings (Complete, request vs response) go first.
_RULES: tuple[tuple[str, str], ...] = (
    ("attach_complete", "Attach complete"),
    ("attach_accept", "Attach accept"),
    ("attach_request", "Attach request"),
    ("identity_response", "Identity response"),
    ("identity_request", "Identity request"),
    ("esm_information_response", "ESM information response"),
    ("esm_information_request", "ESM information request"),
    ("security_mode_complete", "SecurityModeComplete"),
    ("security_mode_command", "SecurityModeCommand"),
    ("rrc_reconfiguration_complete", "RRCConnectionReconfigurationComplete"),
    ("rrc_reconfiguration", "RRCConnectionReconfiguration"),
    ("rrc_connection_setup_complete", "RRCConnectionSetupComplete"),
    ("rrc_connection_setup", "RRCConnectionSetup"),
    ("rrc_connection_request", "RRCConnectionRequest"),
    ("measurement_report", "MeasurementReport"),
    ("tau_request", "Tracking area update request"),
    ("tau_accept", "Tracking area update accept"),
    ("detach_request", "Detach request"),
    ("registration_request", "Registration request"),
    ("registration_accept", "Registration accept"),
)


@dataclass(frozen=True)
class Event:
    frame: int
    t_rel: float
    protocol: str
    kind: str
    info: str


def classify_summary_line(line: str) -> Event | None:
    """Parse one tshark fields line: frame, time_relative, protocol, info."""
    raw = line.rstrip("\n")
    if not raw or raw.startswith("#"):
        return None
    parts = raw.split("\t", 3)
    if len(parts) < 4:
        return None
    frame_s, t_s, protocol, info = parts
    if protocol.startswith("LTE RRC PCCH"):
        return None
    kind = _kind_for(info)
    if kind is None:
        return None
    try:
        frame = int(frame_s)
        t_rel = float(t_s)
    except ValueError:
        return None
    return Event(frame=frame, t_rel=t_rel, protocol=protocol, kind=kind, info=info)


def classify_summary_file(path: Path) -> list[Event]:
    return list(classify_summary_lines(path.read_text(encoding="utf-8", errors="replace").splitlines()))


def classify_summary_lines(lines: Iterable[str]) -> list[Event]:
    events: list[Event] = []
    for line in lines:
        ev = classify_summary_line(line)
        if ev is not None:
            events.append(ev)
    return events


def _kind_for(info: str) -> str | None:
    for kind, needle in _RULES:
        if needle in info:
            return kind
    return None
