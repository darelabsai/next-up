from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "observe-focused-attention.py"
EPOCH = "11111111-1111-1111-1111-111111111111"


class FocusedAttentionObserverTests(unittest.TestCase):
    def make_probe(self, root: Path, responses: list[dict[str, object]]) -> Path:
        probe = root / "probe.py"
        response_path = root / "responses.json"
        response_path.write_text(json.dumps(responses))
        probe.write_text(
            "#!/usr/bin/env python3\n"
            "import json, pathlib, sys\n"
            f"root = pathlib.Path({str(root)!r})\n"
            "if sys.argv[1] == '--alert-list-probe':\n"
            "  sys.stdin.read()\n"
            f"  print(json.dumps({{'candidates':[{{'kind':'completion','laneID':'opaque-lane','navigationTarget':{{'windowID':'w','workspaceID':'ws','paneID':'p','surfaceID':'s'}}}}],'readiness':{{'processEpoch':'{EPOCH}','appliedPollSequence':4,'appliedBaselineGeneration':4}}}}))\n"
            "elif sys.argv[1] == '--focused-lane-probe':\n"
            "  sys.stdin.read()\n"
            "  responses = json.loads((root / 'responses.json').read_text())\n"
            "  count_path = root / 'count'\n"
            "  count = int(count_path.read_text()) if count_path.exists() else 0\n"
            "  count_path.write_text(str(count + 1))\n"
            "  print(json.dumps(responses[min(count, len(responses) - 1)]))\n"
            "else:\n"
            "  raise SystemExit(2)\n"
        )
        probe.chmod(0o755)
        return probe

    def run_observer(
        self, probe: Path, output: Path, acceptance_case: str, timeout: str = "2"
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "python3", "-B", SCRIPT,
                "--lane-id", "opaque-lane",
                "--kind", "completion",
                "--acceptance-case", acceptance_case,
                "--timeout", timeout,
                "--poll-interval", "0.01",
                "--app-executable", probe,
                "--output", output,
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_suppression_accepts_receipt_before_durable_pending_visibility(self) -> None:
        response = {
            "exactlyFocused": True,
            "cmuxFrontmost": True,
            "authoritativePending": False,
            "receiptAccepted": True,
            "acceptedReceiptSequence": 5,
            "processEpoch": EPOCH,
            "appliedPollSequence": 5,
            "appliedBaselineGeneration": 5,
        }
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            probe = self.make_probe(root, [response])
            output = root / "receipt.json"
            result = self.run_observer(probe, output, "focused-suppression")
            payload = json.loads(output.read_text())

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "")
        self.assertEqual(
            set(payload),
            {
                "schema", "acceptance_case", "kind", "lane_id", "route_ids",
                "readiness", "accepted_receipt_sequence", "observed_applied_sequence",
                "observed_baseline_generation", "required_baseline_generation",
                "process_epoch", "exactly_focused", "cmux_frontmost",
                "receipt_accepted", "pending_true_observed", "authoritative_pending_after",
            },
        )
        self.assertEqual(payload["acceptance_case"], "focused-suppression")
        self.assertFalse(payload["pending_true_observed"])
        self.assertFalse(payload["authoritative_pending_after"])
        self.assertEqual(payload["accepted_receipt_sequence"], 5)
        self.assertEqual(payload["route_ids"], {
            "window": "w", "workspace": "ws", "pane": "p", "surface": "s"
        })
        self.assertNotIn("title", json.dumps(payload))

    def test_later_focus_proves_pending_true_to_false_after_two_baselines(self) -> None:
        responses = [
            {
                "exactlyFocused": False,
                "cmuxFrontmost": False,
                "authoritativePending": True,
                "receiptAccepted": False,
                "processEpoch": EPOCH,
                "appliedPollSequence": 5,
                "appliedBaselineGeneration": 5,
            },
            {
                "exactlyFocused": True,
                "cmuxFrontmost": True,
                "authoritativePending": False,
                "receiptAccepted": True,
                "acceptedReceiptSequence": 6,
                "processEpoch": EPOCH,
                "appliedPollSequence": 6,
                "appliedBaselineGeneration": 5,
            },
            {
                "exactlyFocused": True,
                "cmuxFrontmost": True,
                "authoritativePending": False,
                "receiptAccepted": True,
                "acceptedReceiptSequence": 6,
                "processEpoch": EPOCH,
                "appliedPollSequence": 9,
                "appliedBaselineGeneration": 6,
            },
        ]
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            probe = self.make_probe(root, responses)
            output = root / "receipt.json"
            result = self.run_observer(probe, output, "later-focus-auto-clear")
            payload = json.loads(output.read_text())

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(payload["pending_true_observed"])
        self.assertFalse(payload["authoritative_pending_after"])
        self.assertEqual(payload["required_baseline_generation"], 6)
        self.assertEqual(payload["observed_baseline_generation"], 6)
        self.assertEqual(payload["accepted_receipt_sequence"], 6)
        self.assertEqual(payload["observed_applied_sequence"], 9)

    def test_timeout_fails_privately_without_partial_output(self) -> None:
        response = {
            "exactlyFocused": False,
            "cmuxFrontmost": False,
            "authoritativePending": True,
            "receiptAccepted": False,
            "processEpoch": EPOCH,
            "appliedPollSequence": 5,
            "appliedBaselineGeneration": 5,
        }
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            probe = self.make_probe(root, [response])
            output = root / "receipt.json"
            environment = os.environ.copy()
            environment["PRIVATE_SENTINEL"] = "must-not-leak"
            result = subprocess.run(
                [
                    "python3", "-B", SCRIPT,
                    "--lane-id", "opaque-lane",
                    "--kind", "completion",
                    "--acceptance-case", "later-focus-auto-clear",
                    "--timeout", "0.05",
                    "--poll-interval", "0.01",
                    "--app-executable", probe,
                    "--output", output,
                ],
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "focused attention observer timed out\n")
        self.assertFalse(output.exists())
        self.assertNotIn("must-not-leak", result.stderr)


if __name__ == "__main__":
    unittest.main()
