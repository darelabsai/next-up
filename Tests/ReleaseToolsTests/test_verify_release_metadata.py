from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "verify-release-metadata.py"
RECEIPT_KEYS = {
    "completion_focused_suppression",
    "input_required_focused_suppression",
    "completion_later_focus_auto_clear",
    "input_required_later_focus_auto_clear",
    "body_click_route_and_foreground",
    "owner_native_card_removal_verification",
    "cleanup",
}


class VerifyReleaseMetadataTests(unittest.TestCase):
    def make_repository_copy(self, destination: Path) -> None:
        for relative in ("CHANGELOG.md", "VERSION"):
            shutil.copy2(ROOT / relative, destination / relative)
        for relative in ("packaging", "docs/releases", "scripts"):
            source = ROOT / relative
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(source, target)

    def run_verifier(self, root: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", "-B", root / "scripts" / SCRIPT.name],
            cwd=root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def set_current_release(
        self,
        root: Path,
        status: str,
        receipts: dict[str, str | None],
    ) -> None:
        catalog_path = root / "docs" / "releases" / "catalog.json"
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        release = catalog["releases"][0]
        release["status"] = status
        release.update(receipts)
        catalog_path.write_text(json.dumps(catalog, indent=2) + "\n", encoding="utf-8")

        record_path = root / "docs" / "releases" / "1.2.0.md"
        lines = record_path.read_text(encoding="utf-8").splitlines()
        replacements = {
            "Status": status,
            "Source-Commit": receipts.get("source_commit"),
            "Artifact-SHA256": receipts.get("artifact_sha256"),
        }
        for index, line in enumerate(lines):
            label = line.partition(":")[0]
            if label in replacements:
                value = replacements[label]
                lines[index] = f"{label}: {'null' if value is None else value}"
        record_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

        human_path = root / "docs" / "releases" / "README.md"
        human = human_path.read_text(encoding="utf-8")
        human = human.replace(
            "| 1.2.0 | 2026-08-08 | 3 | reviewed |",
            f"| 1.2.0 | 2026-08-08 | 3 | {status} |",
        )
        human_path.write_text(human, encoding="utf-8")

    def test_unmodified_release_metadata_passes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_repository_copy(root)
            result = self.run_verifier(root)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PASS: release metadata synchronized", result.stdout)

    def test_schema_two_has_closed_exact_1_2_acceptance_receipts(self) -> None:
        catalog = json.loads((ROOT / "docs/releases/catalog.json").read_text())
        self.assertEqual(catalog["schema_version"], 2)
        current = catalog["releases"][0]
        self.assertEqual(current["version"], "1.2.0")
        self.assertEqual(set(current["acceptance_receipts"]), RECEIPT_KEYS)
        self.assertEqual(set(current["acceptance_receipts"].values()), {False})
        for historical in catalog["releases"][1:]:
            self.assertIsNone(historical["acceptance_receipts"])

    def test_acceptance_receipt_keys_and_boolean_types_fail_closed(self) -> None:
        mutations = {
            "missing": lambda receipts: receipts.pop("completion_focused_suppression"),
            "extra": lambda receipts: receipts.update({"unexpected": False}),
            "non_boolean": lambda receipts: receipts.update({"cleanup": 0}),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self.make_repository_copy(root)
                path = root / "docs/releases/catalog.json"
                catalog = json.loads(path.read_text())
                mutate(catalog["releases"][0]["acceptance_receipts"])
                path.write_text(json.dumps(catalog, indent=2) + "\n")

                result = self.run_verifier(root)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("acceptance_receipts", result.stderr)

    def test_catalog_keys_types_order_and_historical_receipts_fail_closed(self) -> None:
        def top_key(catalog: dict[str, object]) -> None:
            catalog["unexpected"] = None

        def release_key(catalog: dict[str, object]) -> None:
            catalog["releases"][0]["unexpected"] = None

        def boolean_build(catalog: dict[str, object]) -> None:
            catalog["releases"][0]["build"] = True

        def historical_receipts(catalog: dict[str, object]) -> None:
            catalog["releases"][1]["acceptance_receipts"] = {}

        def current_not_first(catalog: dict[str, object]) -> None:
            catalog["releases"][0], catalog["releases"][1] = (
                catalog["releases"][1],
                catalog["releases"][0],
            )

        mutations = {
            "top-key": top_key,
            "release-key": release_key,
            "boolean-build": boolean_build,
            "historical-receipts": historical_receipts,
            "current-order": current_not_first,
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self.make_repository_copy(root)
                path = root / "docs/releases/catalog.json"
                catalog = json.loads(path.read_text())
                mutate(catalog)
                path.write_text(json.dumps(catalog, indent=2) + "\n")

                result = self.run_verifier(root)

                self.assertNotEqual(result.returncode, 0)

    def test_each_pending_record_receipt_is_synchronized(self) -> None:
        labels = (
            "Completion-Focused-Suppression",
            "Input-Required-Focused-Suppression",
            "Completion-Later-Focus-Auto-Clear",
            "Input-Required-Later-Focus-Auto-Clear",
            "Body-Click-Route-And-Foreground",
            "Owner-Native-Card-Removal-Verification",
            "Cleanup",
        )
        for label in labels:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self.make_repository_copy(root)
                path = root / "docs/releases/1.2.0.md"
                text = path.read_text()
                path.write_text(text.replace(f"{label}: pending", f"{label}: passed"))

                result = self.run_verifier(root)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{label} does not match catalog", result.stderr)

    def test_receipts_are_false_before_live_acceptance_and_true_at_live_acceptance(self) -> None:
        cases = (("reviewed", True, False), ("live-accepted", True, True))
        for status, value, should_pass in cases:
            with self.subTest(status=status), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self.make_repository_copy(root)
                path = root / "docs/releases/catalog.json"
                catalog = json.loads(path.read_text())
                release = catalog["releases"][0]
                release["status"] = status
                release["acceptance_receipts"] = dict.fromkeys(RECEIPT_KEYS, value)
                if status == "live-accepted":
                    release.update(
                        source_commit="a" * 40,
                        artifact_sha256="b" * 64,
                        signing_mode="adhoc",
                        deployment_identity="ai.darelabs.nextup",
                    )
                path.write_text(json.dumps(catalog, indent=2) + "\n")
                self._synchronize_current_record_and_table(root, release)

                result = self.run_verifier(root)

                self.assertEqual(result.returncode == 0, should_pass, result.stderr)

    def _synchronize_current_record_and_table(
        self, root: Path, release: dict[str, object]
    ) -> None:
        record_path = root / "docs/releases/1.2.0.md"
        lines = record_path.read_text().splitlines()
        values = {
            "Status": release["status"],
            "Source-Commit": release["source_commit"],
            "Artifact-SHA256": release["artifact_sha256"],
        }
        receipt_labels = {
            "completion_focused_suppression": "Completion-Focused-Suppression",
            "input_required_focused_suppression": "Input-Required-Focused-Suppression",
            "completion_later_focus_auto_clear": "Completion-Later-Focus-Auto-Clear",
            "input_required_later_focus_auto_clear": "Input-Required-Later-Focus-Auto-Clear",
            "body_click_route_and_foreground": "Body-Click-Route-And-Foreground",
            "owner_native_card_removal_verification": "Owner-Native-Card-Removal-Verification",
            "cleanup": "Cleanup",
        }
        values.update(
            {
                receipt_labels[key]: "passed" if value else "pending"
                for key, value in release["acceptance_receipts"].items()
            }
        )
        for index, line in enumerate(lines):
            label = line.partition(":")[0]
            if label in values:
                value = values[label]
                lines[index] = f"{label}: {'null' if value is None else value}"
        record_path.write_text("\n".join(lines) + "\n")
        table = root / "docs/releases/README.md"
        text = table.read_text()
        text = text.replace(
            "| 1.2.0 | 2026-08-08 | 3 | reviewed |",
            f"| 1.2.0 | 2026-08-08 | 3 | {release['status']} |",
        )
        table.write_text(text)

    def test_every_human_catalog_field_must_match_machine_catalog(self) -> None:
        replacements = {
            "date": (
                "| 1.2.0 | 2026-08-08 | 3 | reviewed | [Next Up 1.2.0](1.2.0.md) |",
                "| 1.2.0 | 1999-01-01 | 3 | reviewed | [Next Up 1.2.0](1.2.0.md) |",
            ),
            "build": (
                "| 1.2.0 | 2026-08-08 | 3 | reviewed | [Next Up 1.2.0](1.2.0.md) |",
                "| 1.2.0 | 2026-08-08 | 999 | reviewed | [Next Up 1.2.0](1.2.0.md) |",
            ),
            "status": (
                "| 1.2.0 | 2026-08-08 | 3 | reviewed | [Next Up 1.2.0](1.2.0.md) |",
                "| 1.2.0 | 2026-08-08 | 3 | deployed | [Next Up 1.2.0](1.2.0.md) |",
            ),
            "record": (
                "| 1.2.0 | 2026-08-08 | 3 | reviewed | [Next Up 1.2.0](1.2.0.md) |",
                "| 1.2.0 | 2026-08-08 | 3 | reviewed | [Next Up 1.2.0](1.0.0.md) |",
            ),
        }
        for field, (old, new) in replacements.items():
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self.make_repository_copy(root)
                catalog = root / "docs" / "releases" / "README.md"
                text = catalog.read_text(encoding="utf-8")
                self.assertIn(old, text)
                catalog.write_text(text.replace(old, new), encoding="utf-8")

                result = self.run_verifier(root)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(
                    f"human catalog {field} does not match catalog for 1.2.0",
                    result.stderr,
                )

    def test_malformed_and_duplicate_human_rows_fail_closed(self) -> None:
        mutations = {
            "malformed": lambda row: row.replace(" | 3 |", " | three |"),
            "duplicate": lambda row: f"{row}\n{row}",
        }
        row = "| 1.2.0 | 2026-08-08 | 3 | reviewed | [Next Up 1.2.0](1.2.0.md) |"
        for mutation, transform in mutations.items():
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self.make_repository_copy(root)
                catalog = root / "docs" / "releases" / "README.md"
                text = catalog.read_text(encoding="utf-8")
                catalog.write_text(text.replace(row, transform(row)), encoding="utf-8")

                result = self.run_verifier(root)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("human release catalog", result.stderr)

    def test_lifecycle_boundaries_require_their_receipts(self) -> None:
        complete: dict[str, str | None] = {
            "source_commit": "a" * 40,
            "artifact_sha256": "b" * 64,
            "signing_mode": "adhoc",
            "deployment_identity": "ai.darelabs.nextup",
        }
        boundaries = {
            "source-verified": ("source_commit",),
            "packaged": ("source_commit", "artifact_sha256", "signing_mode"),
            "deployed": tuple(complete),
            "live-accepted": tuple(complete),
            "superseded": tuple(complete),
        }
        for status, required_fields in boundaries.items():
            for missing in required_fields:
                with (
                    self.subTest(status=status, missing=missing),
                    tempfile.TemporaryDirectory() as temporary,
                ):
                    root = Path(temporary)
                    self.make_repository_copy(root)
                    receipts = complete.copy()
                    receipts[missing] = None
                    self.set_current_release(root, status, receipts)

                    result = self.run_verifier(root)

                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(
                        f"status {status} requires {missing}", result.stderr
                    )

    def test_lifecycle_rejects_receipts_from_later_states(self) -> None:
        cases = {
            "reviewed": {"source_commit": "a" * 40},
            "source-verified": {
                "source_commit": "a" * 40,
                "artifact_sha256": "b" * 64,
            },
            "packaged": {
                "source_commit": "a" * 40,
                "artifact_sha256": "b" * 64,
                "signing_mode": "adhoc",
                "deployment_identity": "ai.darelabs.nextup",
            },
        }
        for status, receipts in cases.items():
            with self.subTest(status=status), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self.make_repository_copy(root)
                complete: dict[str, str | None] = {
                    "source_commit": None,
                    "artifact_sha256": None,
                    "signing_mode": None,
                    "deployment_identity": None,
                }
                complete.update(receipts)
                self.set_current_release(root, status, complete)

                result = self.run_verifier(root)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"status {status} forbids", result.stderr)


if __name__ == "__main__":
    unittest.main()
