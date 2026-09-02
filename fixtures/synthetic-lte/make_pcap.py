#!/usr/bin/env python3
"""Build the synthetic LTE mobility pcap used by the field analyzer tests.

Real captures hold subscriber identities and stay untracked, so the dissected-field
analyzer is developed against hand-encoded LTE RRC/NAS messages instead. Every
message here is UPER-encoded by hand and verified by tshark; regenerate with:

    .venv/bin/python fixtures/synthetic-lte/make_pcap.py

The bit layouts follow 36.331 as Wireshark 4.7 dissects it. One deviation is
marked below: MeasResults carries two root optional bits, not the one the older
published grammar shows.
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path

OUT = Path(__file__).with_name("lte-mobility.pcap")

GSMTAP_TYPE_LTE_RRC = 0x0D
GSMTAP_TYPE_LTE_NAS = 0x12
LTE_RRC_DL_DCCH = 1
LTE_RRC_UL_DCCH = 3


class Bits:
    """Just enough UPER to hand-encode a few RRC messages."""

    def __init__(self) -> None:
        self.bits: list[int] = []

    def bit(self, value: int) -> "Bits":
        self.bits.append(1 if value else 0)
        return self

    def raw(self, value: int, width: int) -> "Bits":
        assert 0 <= value < (1 << width), (value, width)
        self.bits.extend((value >> i) & 1 for i in range(width - 1, -1, -1))
        return self

    def cint(self, value: int, lo: int, hi: int) -> "Bits":
        """Constrained INTEGER with a range small enough to stay in one field."""
        assert lo <= value <= hi, (value, lo, hi)
        return self.raw(value - lo, (hi - lo).bit_length())

    def enum(self, index: int, count: int, extensible: bool = False) -> "Bits":
        if extensible:
            self.bit(0)
        return self.raw(index, max(1, (count - 1).bit_length()))

    choice = enum

    def to_bytes(self) -> bytes:
        bits = self.bits + [0] * (-len(self.bits) % 8)
        return bytes(
            int("".join(str(b) for b in bits[i : i + 8]), 2) for i in range(0, len(bits), 8)
        )


def _ul_dcch(b: Bits, index: int) -> None:
    b.choice(0, 2)          # UL-DCCH-MessageType: c1
    b.choice(index, 16)


def _dl_dcch(b: Bits, index: int) -> None:
    b.choice(0, 2)          # DL-DCCH-MessageType: c1
    b.choice(index, 16)


def measurement_report(meas_id, pcell_rsrp, pcell_rsrq, neighbours=()):
    b = Bits()
    _ul_dcch(b, 1)          # measurementReport
    b.choice(0, 2)          # criticalExtensions: c1
    b.choice(0, 4)          # c1: measurementReport-r8
    b.bit(0)                # nonCriticalExtension absent
    # MeasResults. Wireshark's grammar has two root optional bits here; only the
    # second one gates measResultNeighCells.
    b.bit(0)                # extension marker
    b.bit(0)
    b.bit(1 if neighbours else 0)
    b.cint(meas_id, 1, 32)
    b.cint(pcell_rsrp, 0, 97)
    b.cint(pcell_rsrq, 0, 34)
    if neighbours:
        b.choice(0, 4, extensible=True)   # measResultNeighCells: measResultListEUTRA
        b.cint(len(neighbours), 1, 8)
        for pci, rsrp, rsrq in neighbours:
            b.bit(0)                      # cgi-Info absent
            b.cint(pci, 0, 503)
            b.bit(0)                      # measResult extension marker
            b.bit(1).bit(1)               # rsrpResult and rsrqResult present
            b.cint(rsrp, 0, 97)
            b.cint(rsrq, 0, 34)
    return b.to_bytes()


def _reconfig_head(b, transaction_id, meas_config, mobility_control):
    _dl_dcch(b, 4)          # rrcConnectionReconfiguration
    b.cint(transaction_id, 0, 3)
    b.choice(0, 2)          # criticalExtensions: c1
    b.choice(0, 8)          # c1: rrcConnectionReconfiguration-r8
    b.bit(meas_config)
    b.bit(mobility_control)
    b.bit(0)                # dedicatedInfoNASList
    b.bit(0)                # radioResourceConfigDedicated
    b.bit(0)                # securityConfigHO
    b.bit(0)                # nonCriticalExtension


def _radio_resource_config_common(b):
    b.bit(0)                # extension marker
    b.raw(0, 9)             # every optional absent
    b.bit(0)                # prach-ConfigInfo absent
    b.cint(0, 0, 837)       # rootSequenceIndex
    b.cint(1, 1, 4)         # n-SB
    b.enum(0, 2)            # hoppingMode: interSubFrame
    b.cint(0, 0, 98)        # pusch-HoppingOffset
    b.bit(0)                # enable64QAM
    b.bit(0)                # groupHoppingEnabled
    b.cint(0, 0, 29)        # groupAssignmentPUSCH
    b.bit(0)                # sequenceHoppingEnabled
    b.cint(0, 0, 7)         # cyclicShift
    b.enum(0, 2)            # ul-CyclicPrefixLength: len1


def handover_command(transaction_id, target_pci, new_ue_identity=0x1234):
    b = Bits()
    _reconfig_head(b, transaction_id, meas_config=0, mobility_control=1)
    b.bit(0)                # MobilityControlInfo extension marker
    b.raw(0, 4)             # carrierFreq, carrierBandwidth, spectrumEmission, rach-ConfigDedicated
    b.cint(target_pci, 0, 503)
    b.enum(3, 8)            # t304: ms200
    b.raw(new_ue_identity, 16)
    _radio_resource_config_common(b)
    return b.to_bytes()


def _meas_config_preamble(b):
    b.bit(0)                # MeasConfig extension marker
    for present in (0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0):
        b.bit(present)      # reportConfigToAddModList and measIdToAddModList only


def _meas_id_to_add_mod(b, meas_id, meas_object_id, report_config_id):
    b.cint(1, 1, 32)        # one entry
    b.cint(meas_id, 1, 32)
    b.cint(meas_object_id, 1, 32)
    b.cint(report_config_id, 1, 32)


def meas_config_a3(transaction_id, meas_id, meas_object_id, report_config_id):
    b = Bits()
    _reconfig_head(b, transaction_id, meas_config=1, mobility_control=0)
    _meas_config_preamble(b)
    b.cint(1, 1, 32)        # ReportConfigToAddModList: one entry
    b.cint(report_config_id, 1, 32)
    b.choice(0, 2)          # reportConfig: reportConfigEUTRA
    b.bit(0)                # ReportConfigEUTRA extension marker
    b.choice(0, 2)          # triggerType: event
    b.choice(2, 5, extensible=True)   # eventId: eventA3
    b.cint(3, -30, 30)      # a3-Offset
    b.bit(0)                # reportOnLeave
    b.cint(2, 0, 30)        # hysteresis
    b.enum(5, 16)           # timeToTrigger: ms128
    b.enum(0, 2)            # triggerQuantity: rsrp
    b.enum(1, 2)            # reportQuantity: both
    b.cint(4, 1, 8)         # maxReportCells
    b.enum(4, 16)           # reportInterval: ms1024
    b.enum(0, 8)            # reportAmount: r1
    _meas_id_to_add_mod(b, meas_id, meas_object_id, report_config_id)
    return b.to_bytes()


def meas_config_b1(transaction_id, meas_id, meas_object_id, report_config_id):
    b = Bits()
    _reconfig_head(b, transaction_id, meas_config=1, mobility_control=0)
    _meas_config_preamble(b)
    b.cint(1, 1, 32)        # ReportConfigToAddModList: one entry
    b.cint(report_config_id, 1, 32)
    b.choice(1, 2)          # reportConfig: reportConfigInterRAT
    b.bit(0)                # ReportConfigInterRAT extension marker
    b.choice(0, 2)          # triggerType: event
    b.choice(0, 2, extensible=True)   # eventId: eventB1
    b.choice(0, 3)          # b1-Threshold: b1-ThresholdUTRA
    b.choice(0, 2)          # b1-ThresholdUTRA: utra-RSCP
    b.cint(20, -5, 91)      # utra-RSCP threshold
    b.cint(2, 0, 30)        # hysteresis
    b.enum(5, 16)           # timeToTrigger: ms128
    b.cint(4, 1, 8)         # maxReportCells
    b.enum(4, 16)           # reportInterval: ms1024
    b.enum(0, 8)            # reportAmount: r1
    _meas_id_to_add_mod(b, meas_id, meas_object_id, report_config_id)
    return b.to_bytes()


def plain_reconfiguration(transaction_id):
    """RRCConnectionReconfiguration with neither measConfig nor mobilityControlInfo."""
    b = Bits()
    _reconfig_head(b, transaction_id, meas_config=0, mobility_control=0)
    return b.to_bytes()


def reconfiguration_complete(transaction_id):
    b = Bits()
    _ul_dcch(b, 2)          # rrcConnectionReconfigurationComplete
    b.cint(transaction_id, 0, 3)
    b.choice(0, 2)          # criticalExtensions: rrcConnectionReconfigurationComplete-r8
    b.bit(0)                # nonCriticalExtension absent
    return b.to_bytes()


# NAS EPS is octet-aligned, so these are written out directly.
NAS_IDENTITY_REQUEST = bytes([0x07, 0x55, 0x01])
NAS_IDENTITY_RESPONSE = bytes([0x07, 0x56, 0x08, 0x39, 0x10, 0x62, 0x54, 0x76, 0x98, 0x10, 0x32])
NAS_TAU_REQUEST = bytes(
    [0x07, 0x48, 0x70]
    + [0x0B, 0xF6, 0x13, 0x00, 0x62, 0x00, 0x01, 0x01, 0x12, 0x34, 0x56, 0x78]
)
NAS_ATTACH_REQUEST = bytes(
    [0x07, 0x41, 0x71, 0x08, 0x39, 0x10, 0x62, 0x54, 0x76, 0x98, 0x10, 0x32]
    + [0x02, 0xF0, 0xF0]
    + [0x00, 0x04, 0x02, 0x01, 0xD0, 0x11]
)


def gsmtap(payload_type: int, sub_type: int, payload: bytes, arfcn: int = 1850) -> bytes:
    header = struct.pack(
        "!BBBBHBBLBBBB", 2, 4, payload_type, 0, arfcn, 0, 0, 0, sub_type, 0, 0, 0
    )
    return header + payload


def udp_over_ipv4(payload: bytes, sport: int = 57000, dport: int = 4729) -> bytes:
    udp = struct.pack("!HHHH", sport, dport, 8 + len(payload), 0) + payload
    ip = struct.pack(
        "!BBHHHBBH4s4s", 0x45, 0, 20 + len(udp), 0, 0x4000, 64, 17, 0,
        bytes([127, 0, 0, 1]), bytes([127, 0, 0, 1]),
    )
    checksum = sum(struct.unpack("!10H", ip))
    while checksum >> 16:
        checksum = (checksum & 0xFFFF) + (checksum >> 16)
    ip = ip[:10] + struct.pack("!H", ~checksum & 0xFFFF) + ip[12:]
    return b"\x00" * 12 + b"\x08\x00" + ip + udp


def write_pcap(path: Path, frames: list[bytes]) -> None:
    with path.open("wb") as fh:
        fh.write(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 262144, 1))
        for i, frame in enumerate(frames):
            fh.write(
                struct.pack(
                    "<IIII", 1767225600 + i // 10, (i * 100000) % 1000000, len(frame), len(frame)
                )
            )
            fh.write(frame)


def build() -> list[bytes]:
    rrc = lambda sub, pdu: udp_over_ipv4(gsmtap(GSMTAP_TYPE_LTE_RRC, sub, pdu))
    nas = lambda pdu: udp_over_ipv4(gsmtap(GSMTAP_TYPE_LTE_NAS, 0, pdu))
    return [
        nas(NAS_ATTACH_REQUEST),
        nas(NAS_IDENTITY_REQUEST),
        nas(NAS_IDENTITY_RESPONSE),
        nas(NAS_TAU_REQUEST),
        # measId 1 reports A3 on the serving frequency, measId 2 reports B1 inter-RAT.
        rrc(LTE_RRC_DL_DCCH, meas_config_a3(0, meas_id=1, meas_object_id=1, report_config_id=1)),
        rrc(LTE_RRC_DL_DCCH, meas_config_b1(1, meas_id=2, meas_object_id=2, report_config_id=2)),
        rrc(LTE_RRC_DL_DCCH, plain_reconfiguration(2)),
        rrc(LTE_RRC_UL_DCCH, reconfiguration_complete(2)),
        rrc(LTE_RRC_UL_DCCH, measurement_report(1, 62, 24, [(250, 71, 27), (301, 55, 18)])),
        rrc(LTE_RRC_UL_DCCH, measurement_report(2, 58, 21)),
        rrc(LTE_RRC_DL_DCCH, handover_command(3, target_pci=250)),
        rrc(LTE_RRC_UL_DCCH, reconfiguration_complete(3)),
    ]


def main() -> int:
    write_pcap(OUT, build())
    print(f"wrote {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
