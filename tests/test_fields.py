import shutil
import unittest
from pathlib import Path

from nasrrc.fields import (
    Analyzer,
    analyze_pcap,
    analyze_pdml,
    lte_rsrp_dbm,
    lte_rsrq_db,
    nr_rsrp_dbm,
    nr_rsrq_db,
)

ROOT = Path(__file__).resolve().parents[1]
PCAP = ROOT / "fixtures" / "synthetic-lte" / "lte-mobility.pcap"

# A reconfiguration whose only content is a radio bearer change. tshark shows the
# same Info string as a handover command, which is why the summary classifier
# cannot tell them apart.
PLAIN_RECONFIG_PDML = """<?xml version="1.0"?>
<pdml>
<packet>
  <proto name="frame">
    <field name="frame.number" show="7"/>
    <field name="frame.time_relative" show="1.500000000"/>
  </proto>
  <proto name="lte_rrc">
    <field name="lte-rrc.DL_DCCH_Message_element" showname="DL-DCCH-Message">
      <field name="lte-rrc.c1" showname="c1: rrcConnectionReconfiguration (4)">
        <field name="lte-rrc.radioResourceConfigDedicated_element" showname="radioResourceConfigDedicated"/>
      </field>
    </field>
  </proto>
</packet>
</pdml>
"""


# 36.331 applies measIdToRemoveList before measIdToAddModList, so this message
# retunes measId 1 rather than deleting it.
RETUNE_PDML = """<?xml version="1.0"?>
<pdml>
<packet>
  <proto name="frame">
    <field name="frame.number" show="3"/>
    <field name="frame.time_relative" show="0.500000000"/>
  </proto>
  <proto name="lte_rrc">
    <field name="lte-rrc.DL_DCCH_Message_element" showname="DL-DCCH-Message">
      <field name="lte-rrc.c1" showname="c1: rrcConnectionReconfiguration (4)">
        <field name="lte-rrc.measConfig_element" showname="measConfig">
          <field name="lte-rrc.measIdToRemoveList" showname="measIdToRemoveList: 1 item">
            <field name="lte-rrc.measId" show="1"/>
          </field>
          <field name="lte-rrc.ReportConfigToAddMod_element" showname="ReportConfigToAddMod">
            <field name="lte-rrc.reportConfigId" show="4"/>
            <field name="lte-rrc.eventA5_element" showname="eventA5"/>
          </field>
          <field name="lte-rrc.MeasIdToAddMod_element" showname="MeasIdToAddMod">
            <field name="lte-rrc.measId" show="1"/>
            <field name="lte-rrc.measObjectId" show="1"/>
            <field name="lte-rrc.reportConfigId" show="4"/>
          </field>
        </field>
      </field>
    </field>
  </proto>
</packet>
</pdml>
"""


def _events(pcap=PCAP):
    return list(analyze_pcap(pcap))


@unittest.skipUnless(shutil.which("tshark"), "tshark not installed")
class SyntheticCaptureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.events = _events()
        cls.by_frame = {ev.frame: ev for ev in cls.events}

    def test_nas_attach_and_identity_still_classified(self) -> None:
        kinds = [ev.kind for ev in self.events if ev.rat == "lte" and ev.protocol == "nas-eps"]
        self.assertEqual(
            kinds, ["attach_request", "identity_request", "identity_response", "tau_request"]
        )

    def test_measurement_report_carries_meas_id_and_levels(self) -> None:
        ev = self.by_frame[9]
        self.assertEqual(ev.kind, "measurement_report")
        self.assertEqual(ev.meas_id, 1)
        self.assertEqual(ev.trigger, "a3")
        serving, first, second = ev.cells
        self.assertEqual(serving.role, "serving")
        self.assertEqual((serving.rsrp, serving.rsrq), (62, 24))
        self.assertEqual((serving.rsrp_dbm, serving.rsrq_db), (-79.0, -8.0))
        self.assertEqual((first.pci, first.rsrp_dbm, first.rsrq_db), (250, -70.0, -6.5))
        self.assertEqual((second.pci, second.rsrp_dbm, second.rsrq_db), (301, -86.0, -11.0))

    def test_trigger_comes_from_the_earlier_meas_config(self) -> None:
        self.assertEqual(self.by_frame[5].meas_config, ((1, "a3"),))
        self.assertEqual(self.by_frame[6].meas_config, ((2, "b1"),))
        self.assertEqual(self.by_frame[10].trigger, "b1")

    def test_only_mobility_control_info_counts_as_handover(self) -> None:
        handovers = [ev for ev in self.events if ev.kind == "handover"]
        self.assertEqual([ev.frame for ev in handovers], [11])
        self.assertEqual(handovers[0].target_pci, 250)
        for frame in (5, 6, 7):
            self.assertEqual(self.by_frame[frame].kind, "rrc_reconfiguration")

    def test_reconfiguration_complete_is_not_a_reconfiguration(self) -> None:
        self.assertEqual(self.by_frame[8].kind, "rrc_reconfiguration_complete")


class PdmlTests(unittest.TestCase):
    def test_reconfiguration_without_mobility_control_info(self) -> None:
        events = list(analyze_pdml([PLAIN_RECONFIG_PDML]))
        self.assertEqual([ev.kind for ev in events], ["rrc_reconfiguration"])
        self.assertIsNone(events[0].target_pci)

    def test_unknown_meas_id_has_no_trigger(self) -> None:
        analyzer = Analyzer()
        self.assertEqual(analyzer.triggers_by_meas_id, {})

    def test_remove_then_add_in_one_message_keeps_the_new_trigger(self) -> None:
        analyzer = Analyzer()
        list(analyze_pdml([RETUNE_PDML], analyzer))
        self.assertEqual(analyzer.triggers_by_meas_id, {1: "a5"})


class ConversionTests(unittest.TestCase):
    def test_lte_ranges_match_the_wireshark_labels(self) -> None:
        self.assertEqual(lte_rsrp_dbm(62), -79.0)
        self.assertEqual(lte_rsrq_db(24), -8.0)
        self.assertEqual(lte_rsrp_dbm(97), -44.0)

    def test_nr_ranges(self) -> None:
        self.assertEqual(nr_rsrp_dbm(100), -57.0)
        self.assertEqual(nr_rsrq_db(1), -43.0)

    def test_missing_values_stay_missing(self) -> None:
        self.assertIsNone(lte_rsrp_dbm(None))
        self.assertIsNone(nr_rsrq_db(None))


if __name__ == "__main__":
    unittest.main()
