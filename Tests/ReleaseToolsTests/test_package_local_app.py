from __future__ import annotations

import hashlib
import os
import plistlib
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "package-local-app.sh"


class PackageLocalAppTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary = tempfile.TemporaryDirectory(prefix="nextup-package-tests-")
        cls.root = Path(cls.temporary.name)
        cls.destination = cls.root / "Next Up.app"
        environment = os.environ.copy()
        environment["NEXTUP_SENTINEL_SECRET"] = "SENTINEL-MUST-NOT-LEAK"
        cls.normal = subprocess.run(
            [str(SCRIPT), "--ad-hoc-sign", str(cls.destination)],
            cwd=ROOT,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        cls.release_hash_after_normal = hashlib.sha256(
            (ROOT / ".build" / "release" / "NextUp").read_bytes()
        ).hexdigest()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temporary.cleanup()

    def run_script(self, *arguments: str, cwd: Path = ROOT) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(SCRIPT), *arguments],
            cwd=cwd,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_normal_signed_package_has_exact_layout_metadata_and_hash(self) -> None:
        self.assertEqual(self.normal.returncode, 0, self.normal.stderr)
        binary = self.destination / "Contents" / "MacOS" / "NextUp"
        plist_path = self.destination / "Contents" / "Info.plist"
        self.assertTrue(binary.is_file())
        self.assertTrue(os.access(binary, os.X_OK))
        self.assertTrue(plist_path.is_file())
        with plist_path.open("rb") as handle:
            plist = plistlib.load(handle)
        self.assertEqual(plist["CFBundleShortVersionString"], "1.2.0")
        self.assertEqual(plist["CFBundleVersion"], "3")
        packaged_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
        self.assertEqual(packaged_hash, self.release_hash_after_normal)
        signature = subprocess.run(
            ["codesign", "--verify", "--strict", "--verbose=2", str(self.destination)],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(signature.returncode, 0, signature.stderr)

    def test_stdout_is_closed_privacy_safe_receipts(self) -> None:
        self.assertNotIn("SENTINEL-MUST-NOT-LEAK", self.normal.stdout + self.normal.stderr)
        lines = self.normal.stdout.splitlines()
        self.assertEqual(len(lines), 3)
        self.assertEqual(lines[0], "version=1.2.0")
        self.assertEqual(lines[1], "build=3")
        self.assertRegex(lines[2], r"^executable_sha256=[0-9a-f]{64}$")

    def test_relative_destination_is_rejected_without_creation(self) -> None:
        relative = f"relative-{os.getpid()}.app"
        result = self.run_script(relative)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((ROOT / relative).exists())

    def test_destination_inside_repository_is_rejected_without_creation(self) -> None:
        destination = ROOT / ".nextup-forbidden-output.app"
        destination.unlink(missing_ok=True)
        result = self.run_script(str(destination))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(destination.exists())

    def test_existing_unmarked_directory_is_unchanged(self) -> None:
        destination = self.root / "Existing.app"
        destination.mkdir()
        sentinel = destination / "keep.txt"
        sentinel.write_text("keep", encoding="utf-8")
        result = self.run_script(str(destination))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")

    def test_destination_symlink_is_unchanged(self) -> None:
        target = self.root / "symlink-target"
        target.mkdir()
        destination = self.root / "Linked.app"
        destination.symlink_to(target, target_is_directory=True)
        result = self.run_script(str(destination))
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(destination.is_symlink())
        self.assertEqual(destination.resolve(), target.resolve())

    def test_user_owned_ancestor_symlink_is_rejected(self) -> None:
        real_parent = self.root / "real-parent"
        nested = real_parent / "nested"
        nested.mkdir(parents=True)
        linked_parent = self.root / "linked-parent"
        linked_parent.symlink_to(real_parent, target_is_directory=True)
        destination = linked_parent / "nested" / "Ancestor.app"

        result = self.run_script(str(destination))

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((nested / "Ancestor.app").exists())

    def test_forged_predictable_marker_directory_is_never_deleted(self) -> None:
        destination = self.root / "ForgedMarker.app"
        process = subprocess.Popen(
            [str(SCRIPT), str(destination)],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        forged = Path(f"{destination}.nextup-package.{process.pid}")
        forged.mkdir()
        (forged / ".nextup-package-marker").write_text(
            "nextup-package-v1\n", encoding="utf-8"
        )
        sentinel = forged / "keep.txt"
        sentinel.write_text("keep", encoding="utf-8")
        try:
            process.communicate(timeout=120)
            self.assertTrue(sentinel.is_file())
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            shutil.rmtree(forged, ignore_errors=True)
            shutil.rmtree(destination, ignore_errors=True)

    def test_concurrent_destination_creation_is_not_modified(self) -> None:
        destination = self.root / "Concurrent.app"
        wrapper_directory = self.root / "wrapper-bin"
        wrapper_directory.mkdir(exist_ok=True)
        wrapper = wrapper_directory / "cp"
        wrapper.write_text(
            "#!/bin/sh\n"
            "case \"${1-}\" in *.build/release/NextUp|.build/release/NextUp) sleep 1 ;; esac\n"
            "exec /bin/cp \"$@\"\n",
            encoding="utf-8",
        )
        wrapper.chmod(0o755)
        environment = os.environ.copy()
        environment["PATH"] = f"{wrapper_directory}:{environment['PATH']}"
        process = subprocess.Popen(
            [str(SCRIPT), str(destination)],
            cwd=ROOT,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        temporary_seen = False
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            if list(self.root.glob(".nextup-package.*")) or list(
                self.root.glob("Concurrent.app.nextup-package.*")
            ):
                temporary_seen = True
                break
            if process.poll() is not None:
                break
            time.sleep(0.01)
        self.assertTrue(temporary_seen, "packager never exposed its private temporary sibling")
        destination.mkdir()
        sentinel = destination / "keep.txt"
        sentinel.write_text("keep", encoding="utf-8")
        stdout, stderr = process.communicate(timeout=120)

        self.assertNotEqual(process.returncode, 0, stdout)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep", stderr)
        self.assertEqual(list(destination.iterdir()), [sentinel])

    def test_substituted_private_directory_is_never_deleted_or_published(self) -> None:
        destination = self.root / "Substitution.app"
        wrapper_directory = self.root / "substitution-wrapper-bin"
        wrapper_directory.mkdir(exist_ok=True)
        wrapper = wrapper_directory / "python3"
        real_python = shutil.which("python3")
        self.assertIsNotNone(real_python)
        wrapper.write_text(
            "#!/bin/sh\n"
            "if [ \"${1-}\" = - ] && [ \"${2-}\" = 9 ]; then sleep 1; fi\n"
            f"exec {real_python} \"$@\"\n",
            encoding="utf-8",
        )
        wrapper.chmod(0o755)
        environment = os.environ.copy()
        environment["PATH"] = f"{wrapper_directory}:{environment['PATH']}"
        process = subprocess.Popen(
            [str(SCRIPT), str(destination)],
            cwd=ROOT,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        private: Path | None = None
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            candidates = list(self.root.glob(".nextup-package.*"))
            if candidates:
                private = candidates[0]
                break
            if process.poll() is not None:
                break
            time.sleep(0.01)
        self.assertIsNotNone(private, "packager never created its private directory")
        assert private is not None
        moved = self.root / "moved-original-private"
        private.rename(moved)
        private.mkdir()
        sentinel = private / "forged-keep.txt"
        sentinel.write_text("keep", encoding="utf-8")

        stdout, stderr = process.communicate(timeout=120)

        self.assertNotEqual(process.returncode, 0, stdout)
        self.assertFalse(destination.exists())
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep", stderr)
        self.assertTrue(moved.is_dir())

    def test_metadata_mismatch_fails_before_build_or_assembly(self) -> None:
        fixture = self.root / "fixture"
        for relative in [
            "scripts/package-local-app.sh",
            "scripts/verify-release-metadata.py",
            "VERSION",
            "packaging/Info.plist",
            "CHANGELOG.md",
            "docs/releases/catalog.json",
            "docs/releases/README.md",
            "docs/releases/1.0.0.md",
            "docs/releases/1.1.0.md",
            "docs/releases/1.2.0.md",
        ]:
            source = ROOT / relative
            destination = fixture / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        (fixture / "VERSION").write_text("9.9.9\n", encoding="utf-8")
        output = self.root / "Mismatch.app"
        result = subprocess.run(
            [str(fixture / "scripts" / "package-local-app.sh"), str(output)],
            cwd=fixture,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())
        self.assertFalse((fixture / ".build").exists())


if __name__ == "__main__":
    unittest.main()
