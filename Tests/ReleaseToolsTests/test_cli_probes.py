from __future__ import annotations

import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXECUTABLE = ROOT / ".build" / "debug" / "NextUp"


class CLIProbeProcessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        subprocess.run(
            ["swift", "build", "-c", "debug", "--product", "NextUp"],
            cwd=ROOT,
            check=True,
            stdout=subprocess.DEVNULL,
        )

    def probe_environment(self, home: str) -> dict[str, str]:
        environment = os.environ.copy()
        environment["HOME"] = home
        environment["CFFIXED_USER_HOME"] = home
        return environment

    def run_probe(
        self,
        argument: str,
        payload: bytes,
        home: str,
    ) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            [EXECUTABLE, argument],
            input=payload,
            cwd=ROOT,
            env=self.probe_environment(home),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=4,
        )

    def assert_open_empty_stdin_times_out(self, argument: str, home: str) -> None:
        process = subprocess.Popen(
            [EXECUTABLE, argument],
            cwd=ROOT,
            env=self.probe_environment(home),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        started = time.monotonic()
        try:
            status = process.wait(timeout=4)
        finally:
            if process.stdin is not None:
                process.stdin.close()
            if process.poll() is None:
                process.kill()
                process.wait()
        elapsed = time.monotonic() - started
        stdout = process.stdout.read() if process.stdout is not None else b""
        stderr = process.stderr.read() if process.stderr is not None else b""
        if process.stdout is not None:
            process.stdout.close()
        if process.stderr is not None:
            process.stderr.close()

        self.assertNotEqual(status, 0)
        self.assertGreaterEqual(elapsed, 1.5)
        self.assertLess(elapsed, 4)
        self.assertEqual(stdout, b"")
        self.assertEqual(stderr, f"{argument[2:].replace('-', ' ')} failed\n".encode())

    def test_both_probe_entry_points_bound_open_empty_stdin(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            for argument in ("--navigation-probe", "--pending-probe"):
                with self.subTest(argument=argument):
                    self.assert_open_empty_stdin_times_out(argument, home)

    def test_pending_probe_handles_eof_malformed_oversized_and_safe_output(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            empty = self.run_probe("--pending-probe", b"", home)
            malformed = self.run_probe("--pending-probe", b"\xff", home)
            oversized = self.run_probe("--pending-probe", b"x" * 4097, home)
            valid = self.run_probe("--pending-probe", b"process-contract-lane\n", home)

        for result in (empty, malformed, oversized):
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b"")
            self.assertEqual(result.stderr, b"pending probe failed\n")
        self.assertEqual(valid.returncode, 0)
        self.assertEqual(valid.stderr, b"")
        self.assertLessEqual(len(valid.stdout), 128)
        self.assertEqual(json.loads(valid.stdout), {"pending": False})
        self.assertNotIn(b"process-contract-lane", valid.stdout)

    def test_navigation_probe_handles_eof_malformed_and_oversized_privately(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            results = (
                self.run_probe("--navigation-probe", b"", home),
                self.run_probe("--navigation-probe", b"{", home),
                self.run_probe("--navigation-probe", b"x" * 4097, home),
            )

        for result in results:
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b"")
            self.assertEqual(result.stderr, b"navigation probe failed\n")
            self.assertLessEqual(len(result.stderr), 64)


if __name__ == "__main__":
    unittest.main()
