from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "verify-release-metadata.py"


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

        record_path = root / "docs" / "releases" / "1.1.0.md"
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
            "| 1.1.0 | 2026-08-08 | 2 | reviewed |",
            f"| 1.1.0 | 2026-08-08 | 2 | {status} |",
        )
        human_path.write_text(human, encoding="utf-8")

    def test_unmodified_release_metadata_passes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_repository_copy(root)
            result = self.run_verifier(root)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PASS: release metadata synchronized", result.stdout)

    def test_every_human_catalog_field_must_match_machine_catalog(self) -> None:
        replacements = {
            "date": (
                "| 1.1.0 | 2026-08-08 | 2 | live-accepted | [Next Up 1.1.0](1.1.0.md) |",
                "| 1.1.0 | 1999-01-01 | 2 | live-accepted | [Next Up 1.1.0](1.1.0.md) |",
            ),
            "build": (
                "| 1.1.0 | 2026-08-08 | 2 | live-accepted | [Next Up 1.1.0](1.1.0.md) |",
                "| 1.1.0 | 2026-08-08 | 999 | live-accepted | [Next Up 1.1.0](1.1.0.md) |",
            ),
            "status": (
                "| 1.1.0 | 2026-08-08 | 2 | live-accepted | [Next Up 1.1.0](1.1.0.md) |",
                "| 1.1.0 | 2026-08-08 | 2 | deployed | [Next Up 1.1.0](1.1.0.md) |",
            ),
            "record": (
                "| 1.1.0 | 2026-08-08 | 2 | live-accepted | [Next Up 1.1.0](1.1.0.md) |",
                "| 1.1.0 | 2026-08-08 | 2 | live-accepted | [Next Up 1.1.0](1.0.0.md) |",
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
                    f"human catalog {field} does not match catalog for 1.1.0",
                    result.stderr,
                )

    def test_malformed_and_duplicate_human_rows_fail_closed(self) -> None:
        mutations = {
            "malformed": lambda row: row.replace(" | 2 |", " | two |"),
            "duplicate": lambda row: f"{row}\n{row}",
        }
        row = "| 1.1.0 | 2026-08-08 | 2 | live-accepted | [Next Up 1.1.0](1.1.0.md) |"
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


if __name__ == "__main__":
    unittest.main()
