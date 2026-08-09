from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/verify-repository-tree.py"


class RepositoryScannerTests(unittest.TestCase):
    def run_scanner(
        self, root: Path, *arguments: str, stdin: str | None = None
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", "-B", SCRIPT, root, *arguments],
            input=stdin,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def make_root(self) -> tempfile.TemporaryDirectory[str]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        for directory in (".github", "Sources", "Tests", "docs", "packaging", "scripts"):
            (root / directory).mkdir()
        for name in ("VERSION", "Package.swift", "README.md", "CHANGELOG.md", "CONTRIBUTING.md"):
            (root / name).write_text("safe\n")
        return temporary

    def initialize_git(self, root: Path) -> None:
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.name", "Scanner Test"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.email", "scanner@example.invalid"], cwd=root, check=True)

    def commit_all(self, root: Path, message: str) -> None:
        subprocess.run(["git", "add", "-A"], cwd=root, check=True)
        subprocess.run(["git", "commit", "-qm", message], cwd=root, check=True)

    def test_canonical_allowlist_includes_github_and_contributing(self) -> None:
        with self.make_root() as name:
            root = Path(name)
            (root / ".github/workflows.yml").write_text("safe\n")
            result = self.run_scanner(root)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_unknown_top_level_symlink_and_nonregular_entries(self) -> None:
        cases = ("unknown", "symlink", "fifo")
        for case in cases:
            with self.subTest(case=case), self.make_root() as name:
                root = Path(name)
                if case == "unknown":
                    (root / "private.txt").write_text("safe\n")
                elif case == "symlink":
                    (root / "Sources/link").symlink_to(root / "README.md")
                else:
                    os.mkfifo(root / "docs/pipe")
                result = self.run_scanner(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("safe", result.stdout + result.stderr)

    def test_path_list_rejects_outside_allowlist_and_excluded_internal_paths(self) -> None:
        with self.make_root() as name:
            root = Path(name)
            (root / ".git").mkdir()
            (root / ".git/config").write_text("safe\n")
            outside = root.parent / "outside-scan-sentinel"
            outside.write_text("safe\n")
            try:
                outside_result = self.run_scanner(
                    root, "--paths-from-stdin", stdin=str(outside) + "\n"
                )
                excluded_result = self.run_scanner(
                    root, "--paths-from-stdin", stdin=".git/config\n"
                )
            finally:
                outside.unlink()
        self.assertNotEqual(outside_result.returncode, 0)
        self.assertNotEqual(excluded_result.returncode, 0)

    def test_privacy_findings_name_the_rule_and_path_never_matched_text(self) -> None:
        token = "gh" + "p_" + "A" * 36
        private_path = "/" + "Users/" + "private-owner/secret.txt"
        with self.make_root() as name:
            root = Path(name)
            target = root / "docs/unsafe.txt"
            target.write_text(f"credential={token}\nlocation={private_path}\n")
            result = self.run_scanner(root, "--paths-from-stdin", stdin="docs/unsafe.txt\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("credential-token", result.stdout)
        self.assertIn("absolute-user-path", result.stdout)
        self.assertIn("docs/unsafe.txt", result.stdout)
        self.assertNotIn(token, result.stdout + result.stderr)
        self.assertNotIn(private_path, result.stdout + result.stderr)

    def test_path_list_is_deduplicated_and_sorted(self) -> None:
        with self.make_root() as name:
            root = Path(name)
            first = root / "docs/z.txt"
            second = root / "Sources/a.swift"
            first.write_text("safe\n")
            second.write_text("safe\n")
            result = self.run_scanner(
                root,
                "--paths-from-stdin",
                "--list-paths",
                stdin="docs/z.txt\nSources/a.swift\ndocs/z.txt\n",
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["Sources/a.swift", "docs/z.txt"])

    def test_rejects_every_forbidden_repository_path_family(self) -> None:
        cases = (
            ".env",
            "docs/research/private.md",
            "docs/plans/private.md",
            "docs/feedback/private.md",
            "docs/releases/1.2.0-files.txt",
            "packaging/ai.darelabs.nextup.plist",
            "scripts/private.log",
            "scripts/Private.app/Contents/file",
        )
        for relative in cases:
            with self.subTest(relative=relative), self.make_root() as name:
                root = Path(name)
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("private-path-sentinel\n")
                result = self.run_scanner(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("private-path-sentinel", result.stdout + result.stderr)

    def test_detects_secret_token_and_private_key_families_without_echoing_values(self) -> None:
        sentinels = (
            "-----BEGIN " + "OPENSSH PRIVATE KEY-----",
            "gh" + "p_" + "A" * 40,
            "github_" + "pat_" + "B" * 30,
            "s" + "k-proj-" + "C" * 30,
            "AK" + "IA" + "D" * 16,
            "Bearer " + "E" * 30,
        )
        with self.make_root() as name:
            root = Path(name)
            target = root / "docs/unsafe.bin"
            target.write_bytes(("\n".join(sentinels)).encode() + b"\xff\x00")
            result = self.run_scanner(root, "--paths-from-stdin", stdin="docs/unsafe.bin\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("credential-token", result.stdout)
        for sentinel in sentinels:
            self.assertNotIn(sentinel, result.stdout + result.stderr)

    def test_schema_only_credential_key_is_allowed_only_in_schema_files(self) -> None:
        key = "source_" + "auth_token"
        with self.make_root() as name:
            root = Path(name)
            schema = root / "docs/event.schema.json"
            fixture = root / "Tests/event.json"
            schema.write_text('{"properties":{"' + key + '":{"type":"string"}}}\n')
            fixture.write_text('{"' + key + '":"<redacted>"}\n')
            schema_result = self.run_scanner(
                root, "--paths-from-stdin", stdin="docs/event.schema.json\n"
            )
            fixture_result = self.run_scanner(
                root, "--paths-from-stdin", stdin="Tests/event.json\n"
            )
        self.assertEqual(schema_result.returncode, 0, schema_result.stderr)
        self.assertNotEqual(fixture_result.returncode, 0)
        self.assertIn("schema-only-auth-token", fixture_result.stdout)
        self.assertNotIn(key, fixture_result.stdout + fixture_result.stderr)

    def test_rejects_tracked_large_files(self) -> None:
        with self.make_root() as name:
            root = Path(name)
            self.initialize_git(root)
            large = root / "docs/large.bin"
            with large.open("wb") as handle:
                handle.truncate(10 * 1024 * 1024 + 1)
            subprocess.run(["git", "add", "docs/large.bin"], cwd=root, check=True)
            result = self.run_scanner(root)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("tracked-large-file", result.stdout)
        self.assertIn("docs/large.bin", result.stdout)

    def test_scans_deleted_git_history_blobs(self) -> None:
        secret = "gh" + "p_" + "H" * 40
        with self.make_root() as name:
            root = Path(name)
            self.initialize_git(root)
            historical = root / "docs/deleted.txt"
            historical.write_text(secret + "\n")
            self.commit_all(root, "add historical secret")
            historical.unlink()
            self.commit_all(root, "remove historical secret")
            working_tree_result = self.run_scanner(root)
            history_result = self.run_scanner(root, "--history")
        self.assertEqual(working_tree_result.returncode, 0, working_tree_result.stderr)
        self.assertNotEqual(history_result.returncode, 0)
        self.assertIn("history-credential-token", history_result.stdout)
        self.assertIn("docs/deleted.txt", history_result.stdout)
        self.assertNotIn(secret, history_result.stdout + history_result.stderr)

    def test_history_checks_every_path_when_allowed_and_forbidden_share_a_blob(self) -> None:
        sentinel = "same-blob-private-sentinel"
        with self.make_root() as name:
            root = Path(name)
            self.initialize_git(root)
            allowed = root / "docs/allowed.txt"
            forbidden = root / "docs/plans/forbidden.txt"
            forbidden.parent.mkdir(parents=True)
            allowed.write_text(sentinel + "\n")
            forbidden.write_text(sentinel + "\n")
            self.commit_all(root, "add identical allowed and forbidden paths")
            allowed.unlink()
            forbidden.unlink()
            forbidden.parent.rmdir()
            self.commit_all(root, "delete identical historical paths")

            result = self.run_scanner(root, "--history")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("history-forbidden-path\tdocs/plans/forbidden.txt", result.stdout)
        self.assertNotIn(sentinel, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
