#!/bin/sh
set -eu

usage() {
    printf 'usage: install-local-app.sh install|rollback <source-app> <installed-app> <displaced-app> <launch-agent> <expected-version> <expected-build> <expected-sha256>\n' >&2
    exit 64
}

[ "$#" -eq 8 ] || usage
case "$1" in install|rollback) ;; *) usage ;; esac

exec /usr/bin/python3 - "$@" <<'PY'
from __future__ import annotations

import ctypes
import errno
import fcntl
import hashlib
import json
import os
import plistlib
import pwd
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

mode, source_path, installed_path, displaced_path, agent_path, expected_version, expected_build, expected_hash = sys.argv[1:]
uid = os.getuid()
label = f"gui/{uid}/ai.darelabs.nextup"
expected_hash = expected_hash.lower()

try:
    canonical_home = pwd.getpwuid(uid).pw_dir
    lock_descriptor: int | None = os.open(
        canonical_home,
        os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
    )
except (KeyError, OSError):
    raise SystemExit("installer lock directory is unavailable")
lock_metadata = os.fstat(lock_descriptor)
if (not stat.S_ISDIR(lock_metadata.st_mode) or lock_metadata.st_uid != uid
        or lock_metadata.st_mode & 0o022):
    raise SystemExit("installer lock directory must be owner-controlled")
try:
    fcntl.flock(lock_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit("another installer transaction is active")
except OSError:
    raise SystemExit("installer lock could not be acquired")

if os.environ.get("NEXTUP_INSTALL_TESTING") == "1" and os.environ.get("NEXTUP_INSTALL_TEST_LOCKED_READY"):
    Path(os.environ["NEXTUP_INSTALL_TEST_LOCKED_READY"]).write_text("ready\n", encoding="utf-8")
    continue_path = Path(os.environ["NEXTUP_INSTALL_TEST_LOCKED_CONTINUE"])
    while not continue_path.exists():
        time.sleep(0.02)

if not re.fullmatch(r"[0-9a-f]{64}", expected_hash):
    raise SystemExit("expected SHA-256 must be 64 lowercase hexadecimal characters")

paths = [source_path, installed_path, displaced_path, agent_path]
for value in paths:
    if not os.path.isabs(value) or os.path.normpath(value) != value:
        raise SystemExit("all path arguments must be absolute and normalized")


def components(path: str) -> list[str]:
    parts = Path(path).parts
    return [os.path.join(*parts[:index]) for index in range(1, len(parts) + 1)]


def reject_symlink_ancestors(path: str) -> None:
    for item in components(path):
        try:
            metadata = os.lstat(item)
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(metadata.st_mode):
            raise SystemExit("path arguments and ancestors must not be symlinks")


for value in paths:
    reject_symlink_ancestors(value)

for required in (source_path, installed_path, agent_path):
    try:
        metadata = os.lstat(required)
    except FileNotFoundError:
        raise SystemExit("required path does not exist")
    if metadata.st_uid != uid or metadata.st_mode & 0o022:
        raise SystemExit("path arguments must be owner-controlled")

if not stat.S_ISDIR(os.lstat(source_path).st_mode) or not stat.S_ISDIR(os.lstat(installed_path).st_mode):
    raise SystemExit("source and installed app arguments must be directories")
if not stat.S_ISREG(os.lstat(agent_path).st_mode):
    raise SystemExit("launch agent must be a regular file")
if os.path.lexists(displaced_path):
    raise SystemExit("displaced app already exists")

parents = [os.path.dirname(value) for value in paths]
for parent in parents:
    metadata = os.lstat(parent)
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != uid or metadata.st_mode & 0o022:
        raise SystemExit("path parents must be owner-controlled directories")
expected_device = os.lstat(source_path).st_dev
if any(os.lstat(parent).st_dev != expected_device for parent in parents):
    raise SystemExit("all arguments must be on the same filesystem")
if os.lstat(installed_path).st_dev != expected_device or os.lstat(agent_path).st_dev != expected_device:
    raise SystemExit("all arguments must be on the same filesystem")

installed_parent_descriptor: int | None = os.open(
    os.path.dirname(installed_path),
    os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
)
displaced_parent_descriptor: int | None = os.open(
    os.path.dirname(displaced_path),
    os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
)


def validate_bound_publication_parents() -> None:
    for path, descriptor in (
        (os.path.dirname(installed_path), installed_parent_descriptor),
        (os.path.dirname(displaced_path), displaced_parent_descriptor),
    ):
        if descriptor is None:
            raise SystemExit("publication parents are not bound")
        bound = os.fstat(descriptor)
        current = os.stat(path, follow_symlinks=False)
        if (bound.st_dev, bound.st_ino) != (current.st_dev, current.st_ino):
            raise SystemExit("publication parent was substituted")


validate_bound_publication_parents()


def validate_tree(path: str) -> None:
    root = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        def visit(directory: int) -> None:
            if os.fstat(directory).st_uid != uid or os.fstat(directory).st_mode & 0o022:
                raise SystemExit("app trees must be owner-controlled")
            for name in os.listdir(directory):
                metadata = os.stat(name, dir_fd=directory, follow_symlinks=False)
                if metadata.st_uid != uid or metadata.st_mode & 0o022 or stat.S_ISLNK(metadata.st_mode):
                    raise SystemExit("app trees must be owner-controlled and non-symlinked")
                if stat.S_ISDIR(metadata.st_mode):
                    child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
                    try:
                        visit(child)
                    finally:
                        os.close(child)
                elif not stat.S_ISREG(metadata.st_mode):
                    raise SystemExit("app trees may contain only directories and regular files")
        visit(root)
    finally:
        os.close(root)


validate_tree(source_path)
validate_tree(installed_path)

production_commands = {
    "ditto": "/usr/bin/ditto",
    "codesign": "/usr/bin/codesign",
    "launchctl": "/bin/launchctl",
    "ps": "/bin/ps",
}
testing = os.environ.get("NEXTUP_INSTALL_TESTING") == "1"
fake_directory = os.environ.get("NEXTUP_INSTALL_COMMAND_DIR")
if fake_directory and not testing:
    raise SystemExit("fake commands require explicit test mode")
if testing:
    if not fake_directory or not os.path.isabs(fake_directory):
        raise SystemExit("test command directory must be absolute")
    reject_symlink_ancestors(fake_directory)
    fake_metadata = os.lstat(fake_directory)
    if not stat.S_ISDIR(fake_metadata.st_mode) or fake_metadata.st_uid != uid:
        raise SystemExit("test command directory must be owner-controlled")
    commands = {name: os.path.join(fake_directory, name) for name in production_commands}
else:
    commands = production_commands


def run(command: list[str]) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)


def descriptor_path(descriptor: int) -> str:
    return os.fsdecode(fcntl.fcntl(descriptor, 50, b"\0" * 1024).split(b"\0", 1)[0])


libc = ctypes.CDLL(None, use_errno=True)
renameatx = libc.renameatx_np
renameatx.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
renameatx.restype = ctypes.c_int
RENAME_EXCLUSIVE = 0x00000004
RENAME_SWAP = 0x00000002
F_FULLFSYNC = 51


def publication_parent_descriptor(path: str) -> int:
    parent = os.path.dirname(path)
    if parent == os.path.dirname(installed_path) and installed_parent_descriptor is not None:
        return installed_parent_descriptor
    if parent == os.path.dirname(displaced_path) and displaced_parent_descriptor is not None:
        return displaced_parent_descriptor
    raise SystemExit("publication path escaped bound parents")


def rename_with_flags(source: str, destination: str, flags: int) -> None:
    source_parent = publication_parent_descriptor(source)
    destination_parent = publication_parent_descriptor(destination)
    result = renameatx(source_parent, os.fsencode(os.path.basename(source)), destination_parent, os.fsencode(os.path.basename(destination)), flags)
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def rename_excl(source: str, destination: str) -> None:
    rename_with_flags(source, destination, RENAME_EXCLUSIVE)


def rename_swap(source: str, destination: str) -> None:
    rename_with_flags(source, destination, RENAME_SWAP)


def full_sync(descriptor: int) -> None:
    try:
        fcntl.fcntl(descriptor, F_FULLFSYNC)
    except OSError:
        try:
            os.fsync(descriptor)
        except OSError:
            os.sync()


def sync_bound_tree(descriptor: int) -> None:
    for name in os.listdir(descriptor):
        metadata = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        if stat.S_ISDIR(metadata.st_mode):
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            try:
                sync_bound_tree(child)
            finally:
                os.close(child)
        elif stat.S_ISREG(metadata.st_mode):
            child = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=descriptor)
            try:
                full_sync(child)
            finally:
                os.close(child)
        else:
            raise SystemExit("app trees may contain only directories and regular files")
    full_sync(descriptor)


def sync_directory(path: str) -> None:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        full_sync(descriptor)
    finally:
        os.close(descriptor)


def sync_publication_directories() -> None:
    descriptors = {installed_parent_descriptor, displaced_parent_descriptor}
    for descriptor in descriptors:
        if descriptor is None:
            raise SystemExit("publication parents are not bound")
        full_sync(descriptor)


def clear_bound_directory(descriptor: int) -> None:
    for name in os.listdir(descriptor):
        expected = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        try:
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
        except OSError as error:
            if error.errno not in (errno.ENOTDIR, errno.ELOOP):
                raise
            current = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if ((current.st_dev, current.st_ino) != (expected.st_dev, expected.st_ino)
                    or not stat.S_ISREG(current.st_mode)):
                raise RuntimeError("cleanup entry identity changed")
            os.unlink(name, dir_fd=descriptor)
            continue
        try:
            opened = os.fstat(child)
            if ((opened.st_dev, opened.st_ino) != (expected.st_dev, expected.st_ino)
                    or not stat.S_ISDIR(opened.st_mode)):
                raise RuntimeError("cleanup directory identity changed")
            clear_bound_directory(child)
            current = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if ((current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino)
                    or not stat.S_ISDIR(current.st_mode)):
                raise RuntimeError("cleanup directory pathname changed")
            os.rmdir(name, dir_fd=descriptor)
        finally:
            os.close(child)


stage_path: str | None = None
stage_descriptor: int | None = None
stage_identity: tuple[int, int] | None = None
predecessor_descriptor: int | None = None
predecessor_identity: tuple[int, int] | None = None
predecessor_receipt: tuple[str, str, str] | None = None
publication_active = False


class InterruptedInstall(SystemExit):
    pass


def cleanup() -> None:
    global stage_descriptor
    if stage_descriptor is None:
        return
    try:
        clear_bound_directory(stage_descriptor)
        if stage_path is not None and stage_identity is not None:
            try:
                current = os.stat(stage_path, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                if stat.S_ISDIR(current.st_mode) and (current.st_dev, current.st_ino) == stage_identity:
                    os.rmdir(stage_path)
    finally:
        os.close(stage_descriptor)
        stage_descriptor = None


def restore_interrupted_publication() -> None:
    global publication_active, stage_descriptor, stage_path
    if not publication_active:
        return
    run([commands["launchctl"], "bootout", label])
    installed_identity = None
    displaced_identity = None
    try:
        installed = os.stat(installed_path, follow_symlinks=False)
        installed_identity = (installed.st_dev, installed.st_ino)
    except FileNotFoundError:
        pass
    try:
        displaced = os.stat(displaced_path, follow_symlinks=False)
        displaced_identity = (displaced.st_dev, displaced.st_ino)
    except FileNotFoundError:
        pass
    if installed_identity == stage_identity and displaced_identity == predecessor_identity:
        rename_swap(installed_path, displaced_path)
        if stage_descriptor is not None:
            os.close(stage_descriptor)
            stage_descriptor = None
            stage_path = None
    elif installed_identity is None and displaced_identity == predecessor_identity:
        rename_excl(displaced_path, installed_path)
    elif installed_identity != predecessor_identity:
        raise SystemExit("signal restoration failed")
    sync_publication_directories()
    restarted = run([commands["launchctl"], "bootstrap", f"gui/{uid}", agent_path])
    if restarted.returncode != 0:
        raise SystemExit("signal restoration failed")
    publication_active = False


def handle_signal(number: int, _frame: object) -> None:
    global publication_active, stage_descriptor, stage_path
    for caught in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(caught, signal.SIG_IGN)
    try:
        restore_interrupted_publication()
        cleanup()
    except BaseException:
        publication_active = False
        if stage_descriptor is not None:
            os.close(stage_descriptor)
            stage_descriptor = None
            stage_path = None
        print("signal restoration failed", file=sys.stderr)
    raise InterruptedInstall(128 + number)


for caught in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(caught, handle_signal)


def inspect_app(path: str) -> tuple[str, str, str]:
    validate_tree(path)
    plist_path = os.path.join(path, "Contents", "Info.plist")
    executable = os.path.join(path, "Contents", "MacOS", "NextUp")
    with open(plist_path, "rb") as handle:
        plist = plistlib.load(handle)
    version = str(plist.get("CFBundleShortVersionString", ""))
    build = str(plist.get("CFBundleVersion", ""))
    signature = run([commands["codesign"], "--verify", "--deep", "--strict", path])
    if signature.returncode != 0:
        raise SystemExit("signature validation failed")
    digest = hashlib.sha256(Path(executable).read_bytes()).hexdigest()
    return version, build, digest


def validate_app(path: str) -> tuple[str, str, str]:
    version, build, digest = inspect_app(path)
    if version != expected_version:
        raise SystemExit("version validation failed")
    if build != expected_build:
        raise SystemExit("build validation failed")
    if digest != expected_hash:
        raise SystemExit("executable hash validation failed")
    return version, build, digest


try:
    os.umask(0o077)
    predecessor_descriptor = os.open(installed_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    predecessor_stat = os.fstat(predecessor_descriptor)
    predecessor_identity = (predecessor_stat.st_dev, predecessor_stat.st_ino)
    predecessor_receipt = inspect_app(descriptor_path(predecessor_descriptor))
    stage_path = tempfile.mkdtemp(prefix=".nextup-install.", dir=os.path.dirname(installed_path))
    os.chmod(stage_path, 0o700)
    stage_descriptor = os.open(stage_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    stage_stat = os.fstat(stage_descriptor)
    stage_identity = (stage_stat.st_dev, stage_stat.st_ino)
    if stage_stat.st_uid != uid or stat.S_IMODE(stage_stat.st_mode) != 0o700:
        raise SystemExit("private stage root validation failed")

    source_descriptor = os.open(source_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        source_identity = os.fstat(source_descriptor)
        copied = run([commands["ditto"], descriptor_path(source_descriptor), descriptor_path(stage_descriptor)])
        if copied.returncode != 0:
            raise SystemExit("staging copy failed")
        current_source = os.stat(source_path, follow_symlinks=False)
        if (current_source.st_dev, current_source.st_ino) != (source_identity.st_dev, source_identity.st_ino):
            raise SystemExit("source app was substituted")
    finally:
        os.close(source_descriptor)

    current_stage = os.stat(stage_path, follow_symlinks=False)
    if (current_stage.st_dev, current_stage.st_ino) != stage_identity:
        raise SystemExit("private stage root was substituted")
    bound_stage_path = descriptor_path(stage_descriptor)
    version, build, digest = validate_app(bound_stage_path)
    sync_bound_tree(stage_descriptor)
    sync_directory(os.path.dirname(stage_path))

    if testing and os.environ.get("NEXTUP_INSTALL_TEST_VALIDATED_STAGE_READY"):
        Path(os.environ["NEXTUP_INSTALL_TEST_VALIDATED_STAGE_READY"]).write_text(stage_path + "\n", encoding="utf-8")
        continue_path = Path(os.environ["NEXTUP_INSTALL_TEST_VALIDATED_STAGE_CONTINUE"])
        while not continue_path.exists():
            time.sleep(0.02)

    validate_bound_publication_parents()
    current_stage = os.stat(stage_path, follow_symlinks=False)
    if (current_stage.st_dev, current_stage.st_ino) != stage_identity:
        raise SystemExit("validated stage was substituted")

    validate_bound_publication_parents()
    current_predecessor = os.stat(installed_path, follow_symlinks=False)
    if (current_predecessor.st_dev, current_predecessor.st_ino) != predecessor_identity:
        raise SystemExit("installed predecessor was substituted")

    publication_active = True
    stopped = run([commands["launchctl"], "bootout", label])
    if stopped.returncode not in (0, 3):
        raise SystemExit("bootout failed")

    executable = os.path.join(installed_path, "Contents", "MacOS", "NextUp")
    process_listing = run([commands["ps"], "-axo", "pid=,ppid=,command="])
    if process_listing.returncode != 0:
        raise SystemExit("process inspection failed")
    for raw in process_listing.stdout.decode("utf-8", "strict").splitlines():
        fields = raw.strip().split(maxsplit=2)
        if len(fields) == 3 and fields[2] == executable:
            raise SystemExit("installed executable is still running")

    def exact_processes() -> list[tuple[int, int]]:
        process_listing = run([commands["ps"], "-axo", "pid=,ppid=,command="])
        if process_listing.returncode != 0:
            raise SystemExit("process inspection failed")
        matches: list[tuple[int, int]] = []
        for raw in process_listing.stdout.decode("utf-8", "strict").splitlines():
            fields = raw.strip().split(maxsplit=2)
            if len(fields) != 3:
                continue
            try:
                pid, ppid = int(fields[0]), int(fields[1])
            except ValueError:
                continue
            if fields[2] == executable:
                matches.append((pid, ppid))
        return matches

    def require_one_process() -> list[tuple[int, int]]:
        matches = exact_processes()
        if len(matches) != 1:
            raise SystemExit("exactly one installed executable process is required")
        if matches[0][1] != 1:
            raise SystemExit("installed executable parent must be process 1")
        return matches

    validate_bound_publication_parents()
    current_predecessor = os.stat(installed_path, follow_symlinks=False)
    if (current_predecessor.st_dev, current_predecessor.st_ino) != predecessor_identity:
        raise SystemExit("installed predecessor was substituted")
    current_stage = os.stat(stage_path, follow_symlinks=False)
    if (current_stage.st_dev, current_stage.st_ino) != stage_identity:
        raise SystemExit("validated stage was substituted")
    original_stage_path = stage_path
    rename_excl(installed_path, displaced_path)
    try:
        if testing and os.environ.get("NEXTUP_INSTALL_TEST_SECOND_RENAME_FAIL") == "1":
            raise OSError(errno.EIO, "injected second publication failure")
        rename_excl(stage_path, installed_path)
    except BaseException:
        try:
            rename_excl(displaced_path, installed_path)
            sync_publication_directories()
            if inspect_app(installed_path) != predecessor_receipt:
                raise SystemExit("restored predecessor identity mismatch")
            restarted = run([commands["launchctl"], "bootstrap", f"gui/{uid}", agent_path])
            if restarted.returncode != 0:
                raise SystemExit("predecessor restart failed")
            require_one_process()
            publication_active = False
        except BaseException as restore_error:
            raise SystemExit("publication failed and immediate restoration failed") from restore_error
        raise SystemExit("publication failed; predecessor restored")
    sync_publication_directories()

    if testing and os.environ.get("NEXTUP_INSTALL_TEST_PUBLISHED_READY"):
        Path(os.environ["NEXTUP_INSTALL_TEST_PUBLISHED_READY"]).write_text("ready\n", encoding="utf-8")
        continue_path = Path(os.environ["NEXTUP_INSTALL_TEST_PUBLISHED_CONTINUE"])
        while not continue_path.exists():
            time.sleep(0.02)

    try:
        validate_bound_publication_parents()
        published_stage = os.stat(installed_path, follow_symlinks=False)
        if (published_stage.st_dev, published_stage.st_ino) != stage_identity:
            raise SystemExit("published candidate identity mismatch")
        version, build, digest = validate_app(descriptor_path(stage_descriptor))
        started = run([commands["launchctl"], "bootstrap", f"gui/{uid}", agent_path])
        if started.returncode != 0:
            raise SystemExit("bootstrap failed")
        version, build, digest = validate_app(installed_path)
        matches = require_one_process()
    except InterruptedInstall:
        raise
    except BaseException as acceptance_error:
        stopped_candidate = run([commands["launchctl"], "bootout", label])
        if stopped_candidate.returncode not in (0, 3):
            raise SystemExit("candidate failed and predecessor restoration failed") from acceptance_error
        if exact_processes():
            raise SystemExit("candidate failed and predecessor restoration failed") from acceptance_error
        try:
            rename_swap(installed_path, displaced_path)
            sync_publication_directories()
            os.close(stage_descriptor)
            stage_descriptor = None
            stage_path = None
            if inspect_app(installed_path) != predecessor_receipt:
                raise SystemExit("restored predecessor identity mismatch")
            restarted = run([commands["launchctl"], "bootstrap", f"gui/{uid}", agent_path])
            if restarted.returncode != 0:
                raise SystemExit("predecessor restart failed")
            require_one_process()
            publication_active = False
        except BaseException as restore_error:
            raise SystemExit("candidate failed and predecessor restoration failed") from restore_error
        raise SystemExit("candidate acceptance failed; predecessor restored") from acceptance_error

    validate_bound_publication_parents()
    sync_bound_tree(stage_descriptor)
    sync_publication_directories()
    previous_signal_mask = signal.pthread_sigmask(
        signal.SIG_BLOCK,
        {signal.SIGHUP, signal.SIGINT, signal.SIGTERM},
    )
    os.close(stage_descriptor)
    stage_descriptor = None
    stage_path = None
    publication_active = False
    signal.pthread_sigmask(signal.SIG_SETMASK, previous_signal_mask)

    if testing and os.environ.get("NEXTUP_INSTALL_TEST_COMMITTED_READY"):
        Path(os.environ["NEXTUP_INSTALL_TEST_COMMITTED_READY"]).write_text("ready\n", encoding="utf-8")
        continue_path = Path(os.environ["NEXTUP_INSTALL_TEST_COMMITTED_CONTINUE"])
        while not continue_path.exists():
            time.sleep(0.02)

    receipt = {
        "mode": mode,
        "version": version,
        "build": build,
        "hash": digest,
        "process_count": len(matches),
        "parent_is_one": matches[0][1] == 1,
    }
    print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
finally:
    if publication_active:
        restore_interrupted_publication()
    cleanup()
    if predecessor_descriptor is not None:
        os.close(predecessor_descriptor)
    if installed_parent_descriptor is not None:
        os.close(installed_parent_descriptor)
    if displaced_parent_descriptor is not None:
        os.close(displaced_parent_descriptor)
    if lock_descriptor is not None:
        os.close(lock_descriptor)
PY
