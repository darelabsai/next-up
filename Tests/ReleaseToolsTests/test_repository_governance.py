from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class RepositoryGovernanceTests(unittest.TestCase):
    def test_macos_ci_runs_release_gates(self) -> None:
        workflow = (ROOT / ".github/workflows/macos-ci.yml").read_text()
        self.assertIn("runs-on: macos-", workflow)
        for command in (
            "swift test",
            "swift build -c release -Xswiftc -warnings-as-errors",
            "unittest discover -s Tests/ReleaseToolsTests",
            "scripts/verify-release-metadata.py",
            "scripts/verify-repository-tree.py",
            "--history",
            "fetch-depth: 0",
            "git diff --check",
        ):
            self.assertIn(command, workflow)

    def test_security_policy_and_code_owners_are_actionable(self) -> None:
        security = (ROOT / "SECURITY.md").read_text().lower()
        owners = (ROOT / ".github/CODEOWNERS").read_text()
        self.assertIn("security advisory", security)
        self.assertIn("do not", security)
        self.assertIn("@shahhaard47", owners)

    def test_contribution_contract_is_explicit_without_protection_claim(self) -> None:
        text = (ROOT / "CONTRIBUTING.md").read_text().lower()
        for phrase in (
            "short-lived",
            "typed branch",
            "ci must pass",
            "independent review",
            "squash",
            "delete",
            "no develop branch",
            "does not claim server-side branch protection",
        ):
            self.assertIn(phrase, text)

    def test_pull_request_template_carries_review_and_release_truth_checks(self) -> None:
        text = (ROOT / ".github/pull_request_template.md").read_text().lower()
        self.assertIn("independent reviewer", text)
        self.assertIn("release metadata", text)
        self.assertIn("privacy scanner", text)
        self.assertIn("runtime swift feature code", text)


if __name__ == "__main__":
    unittest.main()
