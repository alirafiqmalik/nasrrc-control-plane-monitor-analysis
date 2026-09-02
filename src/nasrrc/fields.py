"""Mobility events from tshark's dissected fields.

The summary classifier in `nasrrc.events` reads the Info column, which cannot tell
a handover from any other RRCConnectionReconfiguration and never carries measIds or
signal levels. This module reads PDML instead, so a measurement report arrives with
its measId, the event that triggered it, and the reported RSRP/RSRQ per cell, and a
reconfiguration is only called a handover when it actually carries
`mobilityControlInfo` (LTE) or `reconfigurationWithSync` (NR).

Works the same over a pcap and over a live GSMTAP stream on an interface, because
tshark streams PDML packet by packet under `-l`.
"""

from __future__ import annotations

import re
import subprocess
import xml.etree.ElementTree as ET
from collections.abc import Iterable, Iterator
from dataclasses import dataclass, field
from pathlib import Path

from nasrrc.events import kind_for_info

GSMTAP_PORT = 4729

# Keeps NR (GSMTAPv3) frames in view on Wireshark builds without a v3 dissector.
DISPLAY_FILTER = "lte_rrc || nas-eps || nr-rrc || nas-5gs"

_RAT_BY_PROTO = {
    "lte_rrc": "lte",
    "nas-eps": "lte",
    "nr-rrc": "nr",
    "nas-5gs": "nr",
}

# RRC message name (as the top-level c1 CHOICE spells it) to the kind we report.
_MESSAGE_KINDS = {
    "measurementReport": "measurement_report",
    "rrcConnectionReconfiguration": "rrc_reconfiguration",
    "rrcConnectionReconfigurationComplete": "rrc_reconfiguration_complete",
    "rrcReconfiguration": "rrc_reconfiguration",
    "rrcReconfigurationComplete": "rrc_reconfiguration_complete",
    "rrcConnectionRequest": "rrc_connection_request",
    "rrcConnectionSetup": "rrc_connection_setup",
    "rrcConnectionSetupComplete": "rrc_connection_setup_complete",
    "rrcSetup": "rrc_connection_setup",
    "rrcSetupComplete": "rrc_connection_setup_complete",
    "securityModeCommand": "security_mode_command",
    "securityModeComplete": "security_mode_complete",
    "mobilityFromEUTRACommand": "inter_rat_handover",
    "mobilityFromNRCommand": "inter_rat_handover",
}

# Element suffixes, matched against the tail of a PDML field name so the same code
# reads both `lte-rrc.` and `nr-rrc.` trees.
_HANDOVER_MARKERS = ("mobilityControlInfo_element", "reconfigurationWithSync_element")
_SERVING_CELL = ("measResultPCell_element", "measResultServingCell_element")
_NEIGHBOUR_CELL = ("MeasResultEUTRA_element", "MeasResultNR_element")
_PCI_FIELDS = ("physCellId", "physCellId_r16")
_TARGET_PCI_FIELDS = ("targetPhysCellId",)
_TARGET_FREQ_FIELDS = ("dl_CarrierFreq", "carrierFreq", "targetCarrierFreq", "absoluteFrequencySSB")

_EVENT_NAME = re.compile(r"\.event([A-B][0-9]+)(?:_[A-Za-z0-9_]+)?_element$")
_CAMEL_BOUNDARY = re.compile(r"(?<=[a-z0-9])(?=[A-Z])")
_NAS_HEX_SUFFIX = re.compile(r"\s*\(0x[0-9a-fA-F]+\)$")


@dataclass(frozen=True)
class CellMeasurement:
    """One reported cell. Raw values are the ASN.1 range indices tshark shows."""

    role: str
    pci: int | None = None
    serv_cell_id: int | None = None
    rsrp: int | None = None
    rsrq: int | None = None
    sinr: int | None = None
    rsrp_dbm: float | None = None
    rsrq_db: float | None = None
    sinr_db: float | None = None

    def describe(self) -> str:
        parts = [self.role if self.pci is None else f"{self.role}=pci{self.pci}"]
        if self.serv_cell_id is not None:
            parts.append(f"servCell={self.serv_cell_id}")
        if self.rsrp_dbm is not None:
            parts.append(f"rsrp={self.rsrp_dbm:g}dBm")
        if self.rsrq_db is not None:
            parts.append(f"rsrq={self.rsrq_db:g}dB")
        if self.sinr_db is not None:
            parts.append(f"sinr={self.sinr_db:g}dB")
        return " ".join(parts)


@dataclass(frozen=True)
class FieldEvent:
    frame: int
    t_rel: float
    protocol: str
    rat: str
    kind: str
    message: str
    meas_id: int | None = None
    trigger: str | None = None
    cells: tuple[CellMeasurement, ...] = ()
    target_pci: int | None = None
    target_freq: int | None = None
    meas_config: tuple[tuple[int, str], ...] = ()

    def describe(self) -> str:
        parts: list[str] = []
        if self.meas_id is not None:
            parts.append(f"measId={self.meas_id}")
        if self.trigger:
            parts.append(f"trigger={self.trigger}")
        if self.target_pci is not None:
            parts.append(f"target=pci{self.target_pci}")
        if self.target_freq is not None:
            parts.append(f"targetFreq={self.target_freq}")
        if self.meas_config:
            configured = ",".join(f"measId{m}={t}" for m, t in self.meas_config)
            parts.append(f"configures {configured}")
        detail = " ".join(parts)
        cells = " | ".join(cell.describe() for cell in self.cells)
        return " | ".join(chunk for chunk in (self.message, detail, cells) if chunk)

    def as_dict(self) -> dict:
        return {
            "frame": self.frame,
            "t_rel": self.t_rel,
            "protocol": self.protocol,
            "rat": self.rat,
            "kind": self.kind,
            "message": self.message,
            "meas_id": self.meas_id,
            "trigger": self.trigger,
            "target_pci": self.target_pci,
            "target_freq": self.target_freq,
            "meas_config": [list(pair) for pair in self.meas_config],
            "cells": [
                {k: v for k, v in vars(cell).items() if v is not None} for cell in self.cells
            ],
        }


# --- signal-level conversions ------------------------------------------------
# Each returns the lower bound of the reported range, which is how 36.133 and 38.133
# define the mapping and how Wireshark labels it.


def lte_rsrp_dbm(value: int) -> float | None:
    return None if value is None else float(-141 + value)


def lte_rsrq_db(value: int) -> float | None:
    return None if value is None else -20.0 + value * 0.5


def nr_rsrp_dbm(value: int) -> float | None:
    return None if value is None else float(-157 + value)


def nr_rsrq_db(value: int) -> float | None:
    return None if value is None else -43.5 + value * 0.5


def nr_sinr_db(value: int) -> float | None:
    return None if value is None else -23.5 + value * 0.5


# --- PDML plumbing -----------------------------------------------------------


def _name(node: ET.Element) -> str:
    return node.get("name", "")


def _ends_with(node: ET.Element, suffixes: tuple[str, ...]) -> bool:
    name = _name(node)
    return any(name.endswith("." + suffix) or name == suffix for suffix in suffixes)


def _descendants(root: ET.Element) -> Iterator[ET.Element]:
    for child in root:
        yield child
        yield from _descendants(child)


def _first(root: ET.Element, suffixes: tuple[str, ...]) -> ET.Element | None:
    for node in _descendants(root):
        if _ends_with(node, suffixes):
            return node
    return None


def _all(root: ET.Element, suffixes: tuple[str, ...]) -> list[ET.Element]:
    return [node for node in _descendants(root) if _ends_with(node, suffixes)]


def _int(root: ET.Element | None, suffixes: tuple[str, ...]) -> int | None:
    if root is None:
        return None
    node = root if not suffixes else _first(root, suffixes)
    if node is None:
        return None
    show = node.get("show", "")
    try:
        # BASE_DEC fields come through decimal, BASE_HEX ones as 0x-prefixed.
        return int(show, 16) if show.startswith("0x") else int(show)
    except ValueError:
        return None


def pdml_packets(chunks: Iterable[str]) -> Iterator[ET.Element]:
    """Yield one Element per `<packet>` as tshark writes them."""
    parser = ET.XMLPullParser(("end",))
    for chunk in chunks:
        parser.feed(chunk)
        for _, element in parser.read_events():
            if element.tag == "packet":
                yield element
                element.clear()
    try:
        parser.close()
    except ET.ParseError:
        # tshark died without closing </pdml>. Whatever arrived has been yielded.
        return
    for _, element in parser.read_events():
        if element.tag == "packet":
            yield element


# --- analysis ----------------------------------------------------------------


@dataclass
class Analyzer:
    """Turns dissected packets into mobility events.

    Report configuration arrives in earlier reconfiguration messages, so the
    analyzer remembers which reporting event each measId belongs to and annotates
    later measurement reports with it.
    """

    triggers_by_meas_id: dict[int, str] = field(default_factory=dict)
    _triggers_by_report_config: dict[int, str] = field(default_factory=dict)

    def feed(self, packet: ET.Element) -> FieldEvent | None:
        frame = _packet_frame(packet)
        if frame is None:
            return None
        frame_number, t_rel = frame
        proto, root = _innermost_signalling_proto(packet)
        if root is None:
            return None
        rat = _RAT_BY_PROTO.get(proto, "")

        if proto in ("nas-eps", "nas-5gs"):
            return _nas_event(frame_number, t_rel, proto, rat, root)

        if _is_broadcast(root):
            # Broadcast and paging carry no mobility events; the summary
            # classifier drops them too.
            return None
        message = _message_name(root)
        if not message:
            return None
        kind = _MESSAGE_KINDS.get(message, _snake(message))

        meas_config = self._learn_meas_config(root)

        if kind == "measurement_report":
            return self._measurement_event(frame_number, t_rel, proto, rat, message, root)
        if kind == "rrc_reconfiguration" and _first(root, _HANDOVER_MARKERS) is not None:
            kind = "handover"
        if kind in ("handover", "inter_rat_handover"):
            marker = _first(root, _HANDOVER_MARKERS)
            return FieldEvent(
                frame=frame_number,
                t_rel=t_rel,
                protocol=proto,
                rat=rat,
                kind=kind,
                message=message,
                target_pci=None if marker is None else _target_pci(marker),
                target_freq=None if marker is None else _int(marker, _TARGET_FREQ_FIELDS),
                meas_config=meas_config,
            )
        return FieldEvent(
            frame=frame_number,
            t_rel=t_rel,
            protocol=proto,
            rat=rat,
            kind=kind,
            message=message,
            meas_config=meas_config,
        )

    def _learn_meas_config(self, root: ET.Element) -> tuple[tuple[int, str], ...]:
        learned: list[tuple[int, str]] = []
        for node in _all(root, ("ReportConfigToAddMod_element",)):
            report_config_id = _int(node, ("reportConfigId",))
            trigger = _trigger_name(node)
            if report_config_id is not None and trigger is not None:
                self._triggers_by_report_config[report_config_id] = trigger
        # 36.331 applies the remove list before the add list, so a single message
        # can retune a measId onto a different reportConfig.
        for removal in _all(root, ("measIdToRemoveList",)):
            for node in _all(removal, ("measId", "MeasId")):
                removed = _int(node, ())
                if removed is not None:
                    self.triggers_by_meas_id.pop(removed, None)
        for node in _all(root, ("MeasIdToAddMod_element",)):
            meas_id = _int(node, ("measId",))
            report_config_id = _int(node, ("reportConfigId",))
            trigger = self._triggers_by_report_config.get(report_config_id)
            if meas_id is not None and trigger is not None:
                self.triggers_by_meas_id[meas_id] = trigger
                learned.append((meas_id, trigger))
        return tuple(learned)

    def _measurement_event(self, frame_number, t_rel, proto, rat, message, root) -> FieldEvent:
        results = _first(root, ("measResults_element",))
        if results is None:
            results = root
        meas_id = _int(results, ("measId",))
        cells: list[CellMeasurement] = []
        # The serving cell has its own field name in both RATs (measResultPCell,
        # measResultServingCell); only list items carry the bare element name.
        # NR wraps each serving entry in a MeasResultServMO carrying servCellId —
        # an EN-DC report has one per measurement object. LTE has a single
        # measResultPCell with no such wrapper.
        for mo in _all(results, ("MeasResultServMO_element",)):
            serving = _first(mo, _SERVING_CELL)
            if serving is not None:
                cells.append(_cell(serving, "serving", rat, _int(mo, ("servCellId",))))
        if not cells:
            serving = _first(results, _SERVING_CELL)
            if serving is not None:
                cells.append(_cell(serving, "serving", rat))
        for neighbour in _all(results, _NEIGHBOUR_CELL):
            cells.append(_cell(neighbour, "neighbour", rat))
        return FieldEvent(
            frame=frame_number,
            t_rel=t_rel,
            protocol=proto,
            rat=rat,
            kind="measurement_report",
            message=message,
            meas_id=meas_id,
            trigger=self.triggers_by_meas_id.get(meas_id),
            cells=tuple(cells),
        )


def _target_pci(marker: ET.Element) -> int | None:
    target = _int(marker, _TARGET_PCI_FIELDS)
    return _int(marker, _PCI_FIELDS) if target is None else target


def _cell(node: ET.Element, role: str, rat: str, serv_cell_id: int | None = None) -> CellMeasurement:
    rsrp = _int(node, ("rsrpResult", "rsrp_Result", "rsrpResult_r15", "rsrp"))
    rsrq = _int(node, ("rsrqResult", "rsrq_Result", "rsrqResult_r15", "rsrq"))
    sinr = _int(node, ("sinr_Result", "sinr"))
    if rat == "nr":
        return CellMeasurement(
            role=role,
            pci=_int(node, _PCI_FIELDS),
            serv_cell_id=serv_cell_id,
            rsrp=rsrp,
            rsrq=rsrq,
            sinr=sinr,
            rsrp_dbm=nr_rsrp_dbm(rsrp),
            rsrq_db=nr_rsrq_db(rsrq),
            sinr_db=nr_sinr_db(sinr),
        )
    return CellMeasurement(
        role=role,
        pci=_int(node, _PCI_FIELDS),
        rsrp=rsrp,
        rsrq=rsrq,
        rsrp_dbm=lte_rsrp_dbm(rsrp),
        rsrq_db=lte_rsrq_db(rsrq),
    )


def _trigger_name(node: ET.Element) -> str | None:
    for descendant in _descendants(node):
        match = _EVENT_NAME.search(_name(descendant))
        if match:
            return match.group(1).lower()
    for descendant in _descendants(node):
        if _name(descendant).endswith(".periodical_element"):
            return "periodical"
    return None


def _nas_event(frame_number, t_rel, proto, rat, root) -> FieldEvent | None:
    labels = [
        node.get("showname", "")
        for node in _descendants(root)
        if "msg_emm_type" in _name(node)
        or "msg_esm_type" in _name(node)
        or _name(node).endswith(".message_type")
    ]
    for label in labels:
        kind = kind_for_info(label)
        if kind is not None:
            return FieldEvent(
                frame=frame_number,
                t_rel=t_rel,
                protocol=proto,
                rat=rat,
                kind=kind,
                message=_NAS_HEX_SUFFIX.sub("", label.split(": ", 1)[-1]),
            )
    return None


def _packet_frame(packet: ET.Element) -> tuple[int, float] | None:
    number = t_rel = None
    for node in _descendants(packet):
        name = _name(node)
        if name == "frame.number":
            number = node.get("show")
        elif name == "frame.time_relative":
            t_rel = node.get("show")
        if number is not None and t_rel is not None:
            break
    if number is None:
        return None
    try:
        return int(number), float(t_rel or 0.0)
    except ValueError:
        return None


def _innermost_signalling_proto(packet: ET.Element) -> tuple[str, ET.Element | None]:
    """The last signalling protocol in the packet, plus its subtree.

    PDML nests a protocol that was dissected out of another one — NAS inside an
    RRC `dedicatedInfoNAS`, say — so the search runs over the whole tree. Each
    protocol also repeats itself as an empty `hide="yes"` node, which is skipped.
    """
    found: tuple[str, ET.Element | None] = ("", None)
    for node in _descendants(packet):
        if node.tag != "proto" or node.get("hide") == "yes":
            continue
        if _name(node) in _RAT_BY_PROTO:
            found = (_name(node), node)
    return found


def _is_broadcast(root: ET.Element) -> bool:
    for node in _descendants(root):
        name = _name(node)
        if name.endswith("_Message_element"):
            channel = name.rsplit(".", 1)[-1]
            return channel.startswith(("BCCH", "PCCH"))
    return False


def _message_name(root: ET.Element) -> str:
    """The top-level c1 CHOICE alternative, e.g. `measurementReport`."""
    for node in _descendants(root):
        if _name(node).endswith(".c1"):
            showname = node.get("showname", "")
            if ": " in showname:
                return showname.split(": ", 1)[1].split(" (", 1)[0]
    return ""


def _snake(name: str) -> str:
    return _CAMEL_BOUNDARY.sub("_", name).replace("-", "_").lower()


# --- entry points ------------------------------------------------------------


def analyze_pdml(chunks: Iterable[str], analyzer: Analyzer | None = None) -> Iterator[FieldEvent]:
    analyzer = analyzer or Analyzer()
    for packet in pdml_packets(chunks):
        event = analyzer.feed(packet)
        if event is not None:
            yield event


def analyze_pcap(path: Path, tshark: str = "tshark") -> Iterator[FieldEvent]:
    argv = [tshark, "-r", str(path), "-T", "pdml", "-Y", DISPLAY_FILTER]
    yield from _run(argv)


def analyze_interface(
    interface: str, port: int = GSMTAP_PORT, host: str | None = None, tshark: str = "tshark"
) -> Iterator[FieldEvent]:
    capture_filter = f"udp port {port}"
    if host:
        capture_filter += f" and dst host {host}"
    argv = [tshark, "-i", interface, "-l", "-f", capture_filter, "-T", "pdml", "-Y", DISPLAY_FILTER]
    yield from _run(argv)


def _run(argv: list[str]) -> Iterator[FieldEvent]:
    try:
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE, text=True, bufsize=1)
    except FileNotFoundError as exc:
        raise RuntimeError(f"{argv[0]} not found; install Wireshark's CLI") from exc
    assert proc.stdout is not None
    try:
        yield from analyze_pdml(proc.stdout)
    except BaseException:
        # The consumer stopped early, so tshark's own exit status is not ours to judge.
        _reap(proc)
        raise
    status = _reap(proc)
    if status:
        # Otherwise a capture that never started looks exactly like a quiet radio.
        raise RuntimeError(f"{argv[0]} exited {status}; see its message above")


def _reap(proc: subprocess.Popen) -> int | None:
    """Stop tshark even when the consumer walked away mid-stream.

    The read end closes first: a tshark blocked writing into a full pipe never
    reaches its own signal handler, so terminate() alone would hang here.
    """
    if proc.stdout is not None:
        proc.stdout.close()
    if proc.poll() is None:
        proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    return proc.returncode
