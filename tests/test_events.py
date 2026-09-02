import unittest
from collections import Counter
from pathlib import Path

from nasrrc.events import classify_summary_file, classify_summary_line

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "fixtures" / "example-lte" / "LTE_full_summary.txt"


class ClassifyLineTests(unittest.TestCase):
    def test_identity_response(self) -> None:
        ev = classify_summary_line(
            "22\t1.602000000\tGSMTAP/NAS-EPS\tIdentity response"
        )
        assert ev is not None
        self.assertEqual(ev.kind, "identity_response")
        self.assertEqual(ev.frame, 22)

    def test_reconfiguration_complete_is_not_reconfiguration(self) -> None:
        ev = classify_summary_line(
            "39\t2.742000000\tLTE RRC UL_DCCH\tRRCConnectionReconfigurationComplete"
        )
        assert ev is not None
        self.assertEqual(ev.kind, "rrc_reconfiguration_complete")

    def test_paging_dropped(self) -> None:
        ev = classify_summary_line(
            "38\t2.742000000\tLTE RRC PCCH\tPaging (1 PagingRecord)"
        )
        self.assertIsNone(ev)


class FixtureTests(unittest.TestCase):
    def test_example_lte_has_attach_identity_and_measurements(self) -> None:
        events = classify_summary_file(FIXTURE)
        counts = Counter(ev.kind for ev in events)
        self.assertGreaterEqual(counts["attach_request"], 1)
        self.assertGreaterEqual(counts["identity_request"], 1)
        self.assertGreaterEqual(counts["identity_response"], 1)
        self.assertGreaterEqual(counts["attach_accept"], 1)
        self.assertGreaterEqual(counts["measurement_report"], 1)
        self.assertGreaterEqual(counts["rrc_reconfiguration"], 1)


if __name__ == "__main__":
    unittest.main()
