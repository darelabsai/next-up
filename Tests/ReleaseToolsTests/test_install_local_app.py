from __future__ import annotations

import hashlib
import json
import os
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "install-local-app.sh"


class InstallLocalAppTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="nextup-installer-tests-")
        self.root = Path(self.temporary.name).resolve()
        self.bin = self.root / "commands"
        self.bin.mkdir(mode=0o700)
        self.log = self.root / "commands.log"
        self.process = self.root / "process.json"
        self.agent = self.root / "ai.darelabs.nextup.plist"
        self.agent.write_text("agent\n", encoding="utf-8")
        self.source = self.root / "Source.app"
        self.installed = self.root / "Installed.app"
        self.displaced = self.root / "Displaced.app"
        self.make_app(self.source, payload=b"candidate", version="1.2.0", build="3")
        self.make_app(self.installed, payload=b"predecessor", version="1.1.0", build="2")
        self.expected_hash = hashlib.sha256(b"candidate").hexdigest()
        self.write_commands()
        self.environment = os.environ.copy()
        self.environment.update(
            {
                "NEXTUP_INSTALL_TESTING": "1",
                "NEXTUP_INSTALL_COMMAND_DIR": str(self.bin),
                "NEXTUP_INSTALL_TEST_LOG": str(self.log),
                "NEXTUP_INSTALL_TEST_PROCESS": str(self.process),
            }
        )
        self.process.write_text(
            json.dumps({"count": 1, "ppid": 1}), encoding="utf-8"
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def make_app(
        self,
        path: Path,
        *,
        payload: bytes,
        version: str,
        build: str,
        signed: bool = True,
    ) -> None:
        executable = path / "Contents" / "MacOS" / "NextUp"
        executable.parent.mkdir(parents=True, mode=0o700)
        executable.write_bytes(payload)
        executable.chmod(0o700)
        with (path / "Contents" / "Info.plist").open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleShortVersionString": version,
                    "CFBundleVersion": build,
                },
                handle,
            )
        if signed:
            (path / "Contents" / "SIGNATURE_GOOD").write_text("yes\n", encoding="utf-8")

    def executable(self, app: Path) -> Path:
        return app / "Contents" / "MacOS" / "NextUp"

    def write_executable(self, name: str, body: str) -> None:
        command = self.bin / name
        command.write_text("#!/bin/sh\nset -eu\n" + body, encoding="utf-8")
        command.chmod(0o700)

    def write_commands(self) -> None:
        self.write_executable(
            "ditto",
            'printf "ditto\\n" >> "$NEXTUP_INSTALL_TEST_LOG"\n'
            '/bin/cp -R "$1"/. "$2"\n'
            'if [ -n "${NEXTUP_INSTALL_TEST_STAGE_READY:-}" ]; then\n'
            '  printf "%s\\n" "$2" > "$NEXTUP_INSTALL_TEST_STAGE_READY"\n'
            '  while [ ! -e "$NEXTUP_INSTALL_TEST_STAGE_CONTINUE" ]; do sleep 0.02; done\n'
            'fi\n',
        )
        self.write_executable(
            "codesign",
            'printf "codesign:%s\\n" "$4" >> "$NEXTUP_INSTALL_TEST_LOG"\n'
            '[ -f "$4/Contents/SIGNATURE_GOOD" ]\n',
        )
        self.write_executable(
            "launchctl",
            'printf "launchctl:%s:%s:%s\\n" "${1-}" "${2-}" "${3-}" >> "$NEXTUP_INSTALL_TEST_LOG"\n'
            'if [ "${1-}" = bootout ]; then exit "${NEXTUP_INSTALL_TEST_BOOTOUT_STATUS:-0}"; fi\n'
            'if [ "${1-}" = bootstrap ]; then\n'
            '  is_candidate=$(/usr/bin/python3 - "$NEXTUP_INSTALL_EXPECTED_EXECUTABLE" <<\'PY\'\n'
            'import plistlib, sys\n'
            'from pathlib import Path\n'
            'with (Path(sys.argv[1]).parents[1] / "Info.plist").open("rb") as h: data=plistlib.load(h)\n'
            'print("1" if data.get("CFBundleShortVersionString") == "1.2.0" else "0")\n'
            'PY\n'
            '  )\n'
            '  if [ "$is_candidate" -eq 1 ] && [ -n "${NEXTUP_INSTALL_TEST_TAMPER:-}" ]; then\n'
            '    /usr/bin/python3 - "$NEXTUP_INSTALL_EXPECTED_EXECUTABLE" "$NEXTUP_INSTALL_TEST_TAMPER" <<\'PY\'\n'
            'import plistlib, sys\n'
            'from pathlib import Path\n'
            'exe, kind = Path(sys.argv[1]), sys.argv[2]\n'
            'app = exe.parents[2]\n'
            'if kind == "hash": exe.write_bytes(b"tampered")\n'
            'elif kind == "signature": (app / "Contents" / "SIGNATURE_GOOD").unlink()\n'
            'else:\n'
            ' p = app / "Contents" / "Info.plist"\n'
            ' with p.open("rb") as h: data = plistlib.load(h)\n'
            ' data["CFBundleShortVersionString" if kind == "version" else "CFBundleVersion"] = "tampered"\n'
            ' with p.open("wb") as h: plistlib.dump(data, h)\n'
            'PY\n'
            '  fi\n'
            '  if [ "$is_candidate" -eq 1 ] && [ "${NEXTUP_INSTALL_TEST_SIGNAL_DURING_CANDIDATE_BOOTSTRAP:-0}" = 1 ]; then\n'
            '    kill -TERM "$PPID"\n'
            '    sleep 0.1\n'
            '  fi\n'
            '  if [ "$is_candidate" -eq 1 ]; then exit "${NEXTUP_INSTALL_TEST_BOOTSTRAP_STATUS:-0}"; fi\n'
            '  exit 0\n'
            'fi\n'
            'exit 99\n',
        )
        self.write_executable(
            "ps",
            'printf "ps\\n" >> "$NEXTUP_INSTALL_TEST_LOG"\n'
            'exec /usr/bin/python3 - "$NEXTUP_INSTALL_TEST_PROCESS" "$NEXTUP_INSTALL_EXPECTED_EXECUTABLE" <<\'PY\'\n'
            'import json, os, sys\n'
            'data=json.load(open(sys.argv[1], encoding="utf-8"))\n'
            'lines=open(os.environ["NEXTUP_INSTALL_TEST_LOG"], encoding="utf-8").read().splitlines()\n'
            'bootstraps=[i for i,line in enumerate(lines) if line.startswith("launchctl:bootstrap:")]\n'
            'bootouts=[i for i,line in enumerate(lines) if line.startswith("launchctl:bootout:")]\n'
            'started=bool(bootstraps) and (not bootouts or bootstraps[-1] > bootouts[-1])\n'
            'for i in range(data.get("count", 0) if started else 0):\n'
            ' print(f"{900+i} {data.get(\'ppid\', 1)} {sys.argv[2]}")\n'
            'for command in data.get("extra", []): print(f"999 1 {command}")\n'
            'PY\n',
        )

    def arguments(
        self,
        mode: str = "install",
        *,
        source: Path | None = None,
        installed: Path | None = None,
        displaced: Path | None = None,
        agent: Path | None = None,
        version: str = "1.2.0",
        build: str = "3",
        expected_hash: str | None = None,
    ) -> list[str]:
        return [
            str(SCRIPT),
            mode,
            str(source or self.source),
            str(installed or self.installed),
            str(displaced or self.displaced),
            str(agent or self.agent),
            version,
            build,
            expected_hash or self.expected_hash,
        ]

    def run_script(
        self,
        mode: str = "install",
        *,
        source: Path | None = None,
        installed: Path | None = None,
        displaced: Path | None = None,
        agent: Path | None = None,
        version: str = "1.2.0",
        build: str = "3",
        expected_hash: str | None = None,
        environment: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        source = source or self.source
        installed = installed or self.installed
        displaced = displaced or self.displaced
        agent = agent or self.agent
        env = self.environment.copy()
        if environment:
            env.update(environment)
        env["NEXTUP_INSTALL_EXPECTED_EXECUTABLE"] = str(self.executable(installed))
        return subprocess.run(
            self.arguments(
                mode,
                source=source,
                installed=installed,
                displaced=displaced,
                agent=agent,
                version=version,
                build=build,
                expected_hash=expected_hash,
            ),
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def assert_success(self, result: subprocess.CompletedProcess[str], mode: str) -> None:
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        lines = result.stdout.splitlines()
        self.assertEqual(len(lines), 1)
        self.assertEqual(
            json.loads(lines[0]),
            {
                "build": "3",
                "hash": self.expected_hash,
                "mode": mode,
                "parent_is_one": True,
                "process_count": 1,
                "version": "1.2.0",
            },
        )
        self.assertEqual(lines[0], json.dumps(json.loads(lines[0]), sort_keys=True, separators=(",", ":")))

    def test_install_success_is_atomic_and_emits_closed_receipt(self) -> None:
        result = self.run_script("install")
        self.assert_success(result, "install")
        self.assertEqual(self.executable(self.installed).read_bytes(), b"candidate")
        self.assertEqual(self.executable(self.displaced).read_bytes(), b"predecessor")
        self.assertTrue(self.source.is_dir())
        log = self.log.read_text(encoding="utf-8")
        self.assertIn(f"launchctl:bootout:gui/{os.getuid()}/ai.darelabs.nextup:", log)
        self.assertIn(f"launchctl:bootstrap:gui/{os.getuid()}:{self.agent}", log)

    def test_rollback_success_uses_the_same_verified_atomic_exchange(self) -> None:
        result = self.run_script("rollback")
        self.assert_success(result, "rollback")
        self.assertEqual(self.executable(self.installed).read_bytes(), b"candidate")
        self.assertEqual(self.executable(self.displaced).read_bytes(), b"predecessor")

    def test_unique_private_stage_does_not_reuse_collision(self) -> None:
        collision = self.root / ".nextup-install.collision"
        collision.mkdir()
        sentinel = collision / "keep.txt"
        sentinel.write_text("keep", encoding="utf-8")
        result = self.run_script()
        self.assert_success(result, "install")
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")
        self.assertEqual(list(self.root.glob(".nextup-install.*")), [collision])

    def test_path_and_ancestor_symlinks_are_rejected_without_mutation(self) -> None:
        linked_source = self.root / "LinkedSource.app"
        linked_source.symlink_to(self.source, target_is_directory=True)
        result = self.run_script(source=linked_source)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.displaced.exists())
        real_parent = self.root / "real-parent"
        real_parent.mkdir()
        linked_parent = self.root / "linked-parent"
        linked_parent.symlink_to(real_parent, target_is_directory=True)
        result = self.run_script(installed=linked_parent / "Installed.app")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((real_parent / "Installed.app").exists())

    def test_same_uid_stage_substitution_survives_while_bound_original_is_cleared(self) -> None:
        ready = self.root / "stage-ready"
        proceed = self.root / "stage-continue"
        environment = self.environment.copy()
        environment.update(
            {
                "NEXTUP_INSTALL_TEST_STAGE_READY": str(ready),
                "NEXTUP_INSTALL_TEST_STAGE_CONTINUE": str(proceed),
                "NEXTUP_INSTALL_EXPECTED_EXECUTABLE": str(self.executable(self.installed)),
            }
        )
        process = subprocess.Popen(
            self.arguments(), cwd=ROOT, env=environment, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        deadline = time.monotonic() + 10
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(ready.exists(), "installer did not expose the staged test checkpoint")
        stage = Path(ready.read_text(encoding="utf-8").strip())
        moved = self.root / "moved-original-stage"
        stage.rename(moved)
        stage.mkdir(mode=0o700)
        sentinel = stage / "replacement-survives.txt"
        sentinel.write_text("keep", encoding="utf-8")
        proceed.touch()
        stdout, stderr = process.communicate(timeout=10)
        self.assertNotEqual(process.returncode, 0, stdout)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep", stderr)
        self.assertEqual(list(moved.iterdir()), [], "bound original inode was not descriptor-cleared")

    def test_same_uid_predecessor_substitution_fails_before_bootout(self) -> None:
        ready = self.root / "predecessor-ready"
        proceed = self.root / "predecessor-continue"
        environment = self.environment.copy()
        environment.update({
            "NEXTUP_INSTALL_TEST_STAGE_READY": str(ready),
            "NEXTUP_INSTALL_TEST_STAGE_CONTINUE": str(proceed),
            "NEXTUP_INSTALL_EXPECTED_EXECUTABLE": str(self.executable(self.installed)),
        })
        process = subprocess.Popen(
            self.arguments(), cwd=ROOT, env=environment, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        deadline = time.monotonic() + 10
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(ready.exists())
        original = self.root / "OriginalPredecessor.app"
        self.installed.rename(original)
        self.make_app(self.installed, payload=b"replacement", version="1.1.0", build="2")
        proceed.touch()
        stdout, _ = process.communicate(timeout=10)

        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(stdout, "")
        self.assertEqual(self.executable(self.installed).read_bytes(), b"replacement")
        self.assertEqual(self.executable(original).read_bytes(), b"predecessor")
        self.assertFalse(self.displaced.exists())
        self.assertNotIn("launchctl:bootout", self.log.read_text(encoding="utf-8"))

    def test_post_validation_stage_substitution_cannot_be_published_or_executed(self) -> None:
        ready = self.root / "validated-stage-ready"
        proceed = self.root / "validated-stage-continue"
        environment = self.environment.copy()
        environment.update({
            "NEXTUP_INSTALL_TEST_VALIDATED_STAGE_READY": str(ready),
            "NEXTUP_INSTALL_TEST_VALIDATED_STAGE_CONTINUE": str(proceed),
            "NEXTUP_INSTALL_EXPECTED_EXECUTABLE": str(self.executable(self.installed)),
        })
        process = subprocess.Popen(
            self.arguments(), cwd=ROOT, env=environment, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        deadline = time.monotonic() + 10
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(ready.exists())
        stage = Path(ready.read_text(encoding="utf-8").strip())
        validated = self.root / "validated-original-stage"
        stage.rename(validated)
        self.make_app(stage, payload=b"unvalidated", version="1.2.0", build="3")
        proceed.touch()
        stdout, _ = process.communicate(timeout=10)

        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(stdout, "")
        self.assertEqual(self.executable(self.installed).read_bytes(), b"predecessor")
        self.assertEqual(self.executable(stage).read_bytes(), b"unvalidated")
        self.assertEqual(list(validated.iterdir()), [])
        self.assertFalse(self.displaced.exists())
        log = self.log.read_text(encoding="utf-8")
        self.assertNotIn("launchctl:bootout", log)
        self.assertNotIn("launchctl:bootstrap", log)

    def test_concurrent_installer_fails_before_stopping_the_locked_transaction(self) -> None:
        ready = self.root / "lock-holder-ready"
        proceed = self.root / "lock-holder-continue"
        holder_environment = self.environment.copy()
        holder_environment.update({
            "NEXTUP_INSTALL_TEST_LOCKED_READY": str(ready),
            "NEXTUP_INSTALL_TEST_LOCKED_CONTINUE": str(proceed),
            "NEXTUP_INSTALL_EXPECTED_EXECUTABLE": str(self.executable(self.installed)),
        })
        holder = subprocess.Popen(
            self.arguments(), cwd=ROOT, env=holder_environment, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        deadline = time.monotonic() + 10
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(ready.exists())

        contender_environment = self.environment.copy()
        contender_environment["NEXTUP_INSTALL_EXPECTED_EXECUTABLE"] = str(self.executable(self.installed))
        contender = subprocess.run(
            self.arguments(), cwd=ROOT, env=contender_environment,
            text=True, capture_output=True, timeout=10,
        )
        self.assertNotEqual(contender.returncode, 0)
        self.assertEqual(contender.stdout, "")
        log = self.log.read_text(encoding="utf-8") if self.log.exists() else ""
        self.assertNotIn("launchctl:bootout", log)

        symlinked_source = self.root / "SymlinkedSource.app"
        symlinked_source.symlink_to(self.source)
        symlinked_contender = subprocess.run(
            self.arguments(source=symlinked_source),
            cwd=ROOT,
            env=contender_environment,
            text=True,
            capture_output=True,
            timeout=10,
        )
        self.assertNotEqual(symlinked_contender.returncode, 0)
        self.assertIn("another installer transaction is active", symlinked_contender.stderr)
        self.assertNotIn("symlink", symlinked_contender.stderr)

        proceed.touch()
        holder_stdout, holder_stderr = holder.communicate(timeout=10)
        self.assertEqual(holder.returncode, 0, holder_stderr)
        self.assertEqual(json.loads(holder_stdout)["version"], "1.2.0")

    def test_installed_parent_substitution_fails_before_bootout(self) -> None:
        installed_parent = self.root / "installed-parent"
        moved_parent = self.root / "moved-installed-parent"
        installed_parent.mkdir(mode=0o700)
        installed = installed_parent / "Installed.app"
        shutil.move(self.installed, installed)
        ready = self.root / "parent-check-ready"
        proceed = self.root / "parent-check-continue"
        environment = self.environment.copy()
        environment.update({
            "NEXTUP_INSTALL_TEST_VALIDATED_STAGE_READY": str(ready),
            "NEXTUP_INSTALL_TEST_VALIDATED_STAGE_CONTINUE": str(proceed),
            "NEXTUP_INSTALL_EXPECTED_EXECUTABLE": str(self.executable(installed)),
        })
        holder = subprocess.Popen(
            self.arguments(installed=installed), cwd=ROOT, env=environment, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        deadline = time.monotonic() + 10
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(ready.exists())

        installed_parent.rename(moved_parent)
        installed_parent.mkdir(mode=0o700)
        shutil.move(moved_parent / "Installed.app", installed)
        alternate_home = self.root / "alternate-home"
        alternate_home.mkdir(mode=0o700)
        contender_environment = self.environment.copy()
        contender_environment["NEXTUP_INSTALL_EXPECTED_EXECUTABLE"] = str(self.executable(installed))
        contender_environment["HOME"] = str(alternate_home)
        contender = subprocess.run(
            self.arguments(installed=installed), cwd=ROOT, env=contender_environment,
            text=True, capture_output=True, timeout=10,
        )
        self.assertNotEqual(contender.returncode, 0)
        self.assertIn("another installer transaction is active", contender.stderr)
        proceed.touch()
        stdout, stderr = holder.communicate(timeout=10)

        self.assertNotEqual(holder.returncode, 0)
        self.assertEqual(stdout, "")
        self.assertIn("publication parent was substituted", stderr)
        log = self.log.read_text(encoding="utf-8") if self.log.exists() else ""
        self.assertNotIn("launchctl:bootout", log)
        self.assertEqual(self.executable(installed).read_bytes(), b"predecessor")
        shutil.rmtree(moved_parent)

    def test_signal_after_publication_restores_predecessor_without_clearing_candidate(self) -> None:
        ready = self.root / "published-ready"
        proceed = self.root / "published-continue"
        environment = self.environment.copy()
        environment.update({
            "NEXTUP_INSTALL_TEST_PUBLISHED_READY": str(ready),
            "NEXTUP_INSTALL_TEST_PUBLISHED_CONTINUE": str(proceed),
            "NEXTUP_INSTALL_EXPECTED_EXECUTABLE": str(self.executable(self.installed)),
        })
        process = subprocess.Popen(
            self.arguments(), cwd=ROOT, env=environment, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        deadline = time.monotonic() + 10
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(ready.exists())
        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=10)

        self.assertEqual(process.returncode, 128 + signal.SIGTERM, stderr)
        self.assertEqual(stdout, "")
        self.assertEqual(self.executable(self.installed).read_bytes(), b"predecessor")
        self.assertEqual(self.executable(self.displaced).read_bytes(), b"candidate")
        self.assertIn("launchctl:bootstrap", self.log.read_text(encoding="utf-8"))

    def test_signal_after_publication_parent_substitution_fails_bounded_without_mutation(self) -> None:
        installed_parent = self.root / "installed-parent"
        moved_parent = self.root / "moved-installed-parent"
        installed_parent.mkdir(mode=0o700)
        installed = installed_parent / "Installed.app"
        displaced = installed_parent / "Displaced.app"
        shutil.move(self.installed, installed)
        ready = self.root / "substituted-published-ready"
        proceed = self.root / "substituted-published-continue"
        environment = self.environment.copy()
        environment.update({
            "NEXTUP_INSTALL_TEST_PUBLISHED_READY": str(ready),
            "NEXTUP_INSTALL_TEST_PUBLISHED_CONTINUE": str(proceed),
            "NEXTUP_INSTALL_EXPECTED_EXECUTABLE": str(self.executable(installed)),
        })
        process = subprocess.Popen(
            self.arguments(installed=installed, displaced=displaced),
            cwd=ROOT,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        deadline = time.monotonic() + 10
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(ready.exists())

        installed_parent.rename(moved_parent)
        installed_parent.mkdir(mode=0o700)
        shutil.move(moved_parent / "Installed.app", installed)
        shutil.move(moved_parent / "Displaced.app", displaced)
        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=10)

        self.assertEqual(process.returncode, 128 + signal.SIGTERM)
        self.assertEqual(stdout, "")
        self.assertEqual(stderr.strip(), "signal restoration failed")
        self.assertNotIn("Traceback", stderr)
        self.assertEqual(self.executable(installed).read_bytes(), b"candidate")
        self.assertEqual(self.executable(displaced).read_bytes(), b"predecessor")
        shutil.rmtree(moved_parent)

    def test_signal_during_candidate_acceptance_restores_predecessor_once(self) -> None:
        result = self.run_script(
            environment={"NEXTUP_INSTALL_TEST_SIGNAL_DURING_CANDIDATE_BOOTSTRAP": "1"}
        )

        self.assertEqual(result.returncode, 128 + signal.SIGTERM, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.executable(self.installed).read_bytes(), b"predecessor")
        self.assertEqual(self.executable(self.displaced).read_bytes(), b"candidate")
        self.assertEqual(
            self.log.read_text(encoding="utf-8").count("launchctl:bootstrap:"),
            2,
        )

    def test_signal_after_durable_acceptance_never_clears_installed_candidate(self) -> None:
        ready = self.root / "committed-ready"
        proceed = self.root / "committed-continue"
        environment = self.environment.copy()
        environment.update({
            "NEXTUP_INSTALL_TEST_COMMITTED_READY": str(ready),
            "NEXTUP_INSTALL_TEST_COMMITTED_CONTINUE": str(proceed),
            "NEXTUP_INSTALL_EXPECTED_EXECUTABLE": str(self.executable(self.installed)),
        })
        process = subprocess.Popen(
            self.arguments(), cwd=ROOT, env=environment, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        deadline = time.monotonic() + 10
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(ready.exists())
        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=10)

        self.assertEqual(process.returncode, 128 + signal.SIGTERM, stderr)
        self.assertEqual(stdout, "")
        self.assertEqual(self.executable(self.installed).read_bytes(), b"candidate")
        self.assertEqual(self.executable(self.displaced).read_bytes(), b"predecessor")

    def test_installer_syncs_candidate_and_publication_directories_before_success(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("F_FULLFSYNC", source)
        self.assertIn("sync_bound_tree(stage_descriptor)", source)
        self.assertIn("sync_publication_directories()", source)
        self.assertIn("os.path.dirname(displaced_path)", source)

    def test_publication_with_distinct_installed_and_displaced_directories_succeeds(self) -> None:
        installed_parent = self.root / "installed-parent"
        displaced_parent = self.root / "displaced-parent"
        installed_parent.mkdir(mode=0o700)
        displaced_parent.mkdir(mode=0o700)
        installed = installed_parent / "Installed.app"
        displaced = displaced_parent / "Displaced.app"
        shutil.move(self.installed, installed)

        result = self.run_script(installed=installed, displaced=displaced)

        self.assert_success(result, "install")
        self.assertEqual(self.executable(installed).read_bytes(), b"candidate")
        self.assertEqual(self.executable(displaced).read_bytes(), b"predecessor")

    def test_all_candidate_validation_happens_before_bootout(self) -> None:
        cases = [
            ("version", "9.9.9"),
            ("build", "999"),
            ("hash", "0" * 64),
        ]
        for field, value in cases:
            with self.subTest(field=field):
                self.log.unlink(missing_ok=True)
                if field == "version":
                    result = self.run_script(version=value)
                elif field == "build":
                    result = self.run_script(build=value)
                else:
                    result = self.run_script(expected_hash=value)
                self.assertNotEqual(result.returncode, 0)
                log = self.log.read_text(encoding="utf-8")
                self.assertNotIn("launchctl:bootout", log)
        (self.source / "Contents" / "SIGNATURE_GOOD").unlink()
        self.log.unlink(missing_ok=True)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("launchctl:bootout", self.log.read_text(encoding="utf-8"))

    def test_bootout_accepts_only_success_or_documented_not_loaded_status(self) -> None:
        accepted = self.run_script(environment={"NEXTUP_INSTALL_TEST_BOOTOUT_STATUS": "3"})
        self.assert_success(accepted, "install")
        # Fresh fixture paths for the rejection half.
        rejected_source = self.root / "RejectedSource.app"
        rejected_installed = self.root / "RejectedInstalled.app"
        rejected_displaced = self.root / "RejectedDisplaced.app"
        self.make_app(rejected_source, payload=b"candidate", version="1.2.0", build="3")
        self.make_app(rejected_installed, payload=b"predecessor", version="1.1.0", build="2")
        rejected = self.run_script(
            source=rejected_source,
            installed=rejected_installed,
            displaced=rejected_displaced,
            environment={"NEXTUP_INSTALL_TEST_BOOTOUT_STATUS": "4"},
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertEqual(self.executable(rejected_installed).read_bytes(), b"predecessor")
        self.assertFalse(rejected_displaced.exists())

    def test_existing_displaced_app_fails_closed(self) -> None:
        self.displaced.mkdir()
        sentinel = self.displaced / "keep.txt"
        sentinel.write_text("keep", encoding="utf-8")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")
        self.assertEqual(self.executable(self.installed).read_bytes(), b"predecessor")

    def test_second_publication_failure_immediately_restores_installed_app(self) -> None:
        result = self.run_script(environment={"NEXTUP_INSTALL_TEST_SECOND_RENAME_FAIL": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.executable(self.installed).read_bytes(), b"predecessor")
        self.assertFalse(self.displaced.exists())
        self.assertEqual(
            self.log.read_text(encoding="utf-8").count("launchctl:bootstrap:"),
            1,
        )

    def test_bootstrap_failure_restores_and_restarts_verified_predecessor(self) -> None:
        result = self.run_script(environment={"NEXTUP_INSTALL_TEST_BOOTSTRAP_STATUS": "5"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.executable(self.installed).read_bytes(), b"predecessor")
        self.assertEqual(self.executable(self.displaced).read_bytes(), b"candidate")
        log = self.log.read_text(encoding="utf-8")
        self.assertEqual(log.count("launchctl:bootstrap:"), 2)

    def test_process_cardinality_and_parent_are_fail_closed(self) -> None:
        for count, ppid in [(0, 1), (2, 1), (1, 2)]:
            with self.subTest(count=count, ppid=ppid):
                source = self.root / f"Source-{count}-{ppid}.app"
                installed = self.root / f"Installed-{count}-{ppid}.app"
                displaced = self.root / f"Displaced-{count}-{ppid}.app"
                self.make_app(source, payload=b"candidate", version="1.2.0", build="3")
                self.make_app(installed, payload=b"predecessor", version="1.1.0", build="2")
                self.process.write_text(json.dumps({"count": count, "ppid": ppid}), encoding="utf-8")
                result = self.run_script(source=source, installed=installed, displaced=displaced)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertEqual(self.executable(installed).read_bytes(), b"predecessor")
                self.assertEqual(self.executable(displaced).read_bytes(), b"candidate")

    def test_exact_installed_process_must_be_gone_before_publication(self) -> None:
        self.process.write_text(
            json.dumps({"count": 1, "ppid": 1, "extra": [str(self.executable(self.installed))]}),
            encoding="utf-8",
        )
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.executable(self.installed).read_bytes(), b"predecessor")
        self.assertFalse(self.displaced.exists())

    def test_post_bootstrap_revalidation_rejects_version_build_hash_and_signature_tampering(self) -> None:
        for kind in ("version", "build", "hash", "signature"):
            with self.subTest(kind=kind):
                source = self.root / f"TamperSource-{kind}.app"
                installed = self.root / f"TamperInstalled-{kind}.app"
                displaced = self.root / f"TamperDisplaced-{kind}.app"
                self.make_app(source, payload=b"candidate", version="1.2.0", build="3")
                self.make_app(installed, payload=b"predecessor", version="1.1.0", build="2")
                self.process.write_text(json.dumps({"count": 1, "ppid": 1}), encoding="utf-8")
                result = self.run_script(
                    source=source,
                    installed=installed,
                    displaced=displaced,
                    environment={"NEXTUP_INSTALL_TEST_TAMPER": kind},
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertEqual(self.executable(installed).read_bytes(), b"predecessor")
                self.assertTrue(displaced.is_dir())

    def test_signal_trap_descriptor_cleans_private_stage(self) -> None:
        ready = self.root / "signal-ready"
        proceed = self.root / "signal-continue"
        environment = self.environment.copy()
        environment.update(
            {
                "NEXTUP_INSTALL_TEST_STAGE_READY": str(ready),
                "NEXTUP_INSTALL_TEST_STAGE_CONTINUE": str(proceed),
                "NEXTUP_INSTALL_EXPECTED_EXECUTABLE": str(self.executable(self.installed)),
            }
        )
        process = subprocess.Popen(
            self.arguments(), cwd=ROOT, env=environment, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        deadline = time.monotonic() + 10
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(ready.exists())
        stage = Path(ready.read_text(encoding="utf-8").strip())
        process.send_signal(signal.SIGTERM)
        process.communicate(timeout=10)
        self.assertNotEqual(process.returncode, 0)
        self.assertFalse(stage.exists())
        self.assertEqual(self.executable(self.installed).read_bytes(), b"predecessor")

    def test_closed_cli_and_fake_commands_are_test_gated(self) -> None:
        wrong = subprocess.run([str(SCRIPT), "install"], text=True, capture_output=True, check=False)
        self.assertEqual(wrong.returncode, 64)
        relative_arguments = self.arguments()
        relative_arguments[2] = "relative.app"
        relative = subprocess.run(relative_arguments, env=self.environment, text=True, capture_output=True, check=False)
        self.assertNotEqual(relative.returncode, 0)
        ungated = self.environment.copy()
        ungated.pop("NEXTUP_INSTALL_TESTING")
        result = subprocess.run(self.arguments(), env=ungated, text=True, capture_output=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.displaced.exists())

    def test_output_never_leaks_environment_or_private_command_output(self) -> None:
        secret = "SENTINEL-MUST-NOT-LEAK"
        result = self.run_script(environment={"NEXTUP_SENTINEL_SECRET": secret})
        self.assert_success(result, "install")
        self.assertNotIn(secret, result.stdout + result.stderr)
        allowed = {"mode", "version", "build", "hash", "process_count", "parent_is_one"}
        self.assertEqual(set(json.loads(result.stdout)), allowed)


if __name__ == "__main__":
    unittest.main()
