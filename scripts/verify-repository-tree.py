#!/usr/bin/env python3
"""Fail-closed repository shape, history, size, and privacy scan."""
from __future__ import annotations

import argparse
import os
import re
import stat
import subprocess
import sys
from pathlib import Path, PurePosixPath

ALLOWED_FILES = {
    ".gitignore",
    "CHANGELOG.md",
    "CONTRIBUTING.md",
    "Package.swift",
    "README.md",
    "SECURITY.md",
    "VERSION",
}
ALLOWED_DIRECTORIES = {".github", "Sources", "Tests", "docs", "packaging", "scripts"}
IGNORED_ROOT_ENTRIES = {".git", ".build"}
MAX_TRACKED_BYTES = 10 * 1024 * 1024

# Compose detector sentinels so this source remains scan-safe.
TOKEN_PATTERNS = (
    re.compile(b"gh" + b"[pousr]_" + b"[A-Za-z0-9]{20,255}"),
    re.compile(b"github_" + b"pat_" + b"[A-Za-z0-9_]{20,255}"),
    re.compile(b"s" + b"k-(?:proj-)?" + b"[A-Za-z0-9_-]{20,255}"),
    re.compile(b"AK" + b"IA" + b"[0-9A-Z]{16}"),
    re.compile(b"Bearer[ \\t]+" + b"[A-Za-z0-9._~-]{20,}", re.IGNORECASE),
    re.compile(b"-----BEGIN " + b"(?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----"),
)
PATH_PATTERNS = (
    re.compile(b"/" + b"Users/(?!Shared(?:/|$))[^/\\s]+(?:/[^\\s'\"`]+)?"),
    re.compile(b"/" + b"home/[^/\\s]+(?:/[^\\s'\"`]+)?"),
    re.compile(b"\\.hermes/" + b"(?:handoffs|cache|workspaces)/"),
)
AUTH_TOKEN_KEY = re.compile(b"source_" + b"auth_token", re.IGNORECASE)


class ScanFailure(Exception):
    pass


def is_schema_path(relative: Path) -> bool:
    lowered = relative.as_posix().lower()
    return (
        lowered.endswith((".schema.json", ".schema.yaml", ".schema.yml"))
        or "/schemas/" in f"/{lowered}/"
    )


def forbidden_path(relative: Path) -> bool:
    parts = relative.parts
    lowered_parts = tuple(part.lower() for part in parts)
    lowered = relative.as_posix().lower()
    if not parts:
        return True
    if parts[0] in {".git", ".build"} or any(
        part in {".git", ".build", ".agents", ".codex", ".hermes", "__pycache__"}
        for part in parts
    ):
        return True
    if parts[0].startswith(".env"):
        return True
    if len(lowered_parts) >= 2 and lowered_parts[:2] in {
        ("docs", "research"),
        ("docs", "plans"),
        ("docs", "feedback"),
    }:
        return True
    if lowered.startswith("docs/releases/") and lowered.endswith("-files.txt"):
        return True
    if lowered == "packaging/ai.darelabs.nextup.plist":
        return True
    if any(part.endswith(".app") for part in lowered_parts) or lowered.endswith(".log"):
        return True
    return False


def relative_allowed(relative: Path) -> bool:
    if forbidden_path(relative):
        return False
    return (
        len(relative.parts) == 1 and relative.name in ALLOWED_FILES
    ) or relative.parts[0] in ALLOWED_DIRECTORIES


def validate_file(root: Path, candidate: Path) -> Path:
    try:
        relative = candidate.relative_to(root)
    except ValueError as exc:
        raise ScanFailure("path is outside repository allowlist") from exc
    if not relative_allowed(relative):
        raise ScanFailure(f"path is outside repository allowlist: {relative.as_posix()}")
    try:
        metadata = candidate.lstat()
    except FileNotFoundError as exc:
        raise ScanFailure(f"listed path does not exist: {relative.as_posix()}") from exc
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise ScanFailure(f"path is not a regular file: {relative.as_posix()}")
    return relative


def canonical_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for entry in os.scandir(root):
        relative = Path(entry.name)
        if entry.name in IGNORED_ROOT_ENTRIES:
            continue
        if entry.is_symlink():
            raise ScanFailure(f"symlink is forbidden: {relative.as_posix()}")
        if entry.is_file(follow_symlinks=False):
            if not relative_allowed(relative):
                raise ScanFailure(f"top-level path is outside allowlist: {relative.as_posix()}")
            files.append(relative)
            continue
        if not entry.is_dir(follow_symlinks=False) or entry.name not in ALLOWED_DIRECTORIES:
            raise ScanFailure(f"top-level path is outside allowlist: {relative.as_posix()}")
        for directory, names, filenames in os.walk(entry.path, followlinks=False):
            current = Path(directory)
            for name in sorted(names):
                child = current / name
                child_relative = child.relative_to(root)
                metadata = child.lstat()
                if (
                    forbidden_path(child_relative)
                    or stat.S_ISLNK(metadata.st_mode)
                    or not stat.S_ISDIR(metadata.st_mode)
                ):
                    raise ScanFailure(f"forbidden internal path: {child_relative.as_posix()}")
            for name in sorted(filenames):
                child = current / name
                child_relative = child.relative_to(root)
                metadata = child.lstat()
                if (
                    not relative_allowed(child_relative)
                    or stat.S_ISLNK(metadata.st_mode)
                    or not stat.S_ISREG(metadata.st_mode)
                ):
                    raise ScanFailure(f"path is not a regular allowed file: {child_relative.as_posix()}")
                files.append(child_relative)
    return sorted(set(files), key=lambda path: path.as_posix())


def listed_files(root: Path, source: str) -> list[Path]:
    if source == "-":
        lines = sys.stdin.read().splitlines()
    else:
        source_path = Path(source)
        if not source_path.is_absolute():
            source_path = root / source_path
        lines = source_path.read_text(encoding="utf-8").splitlines()
    paths: set[Path] = set()
    for line in lines:
        if not line:
            continue
        candidate = Path(line)
        if not candidate.is_absolute():
            candidate = root / candidate
        paths.add(validate_file(root, candidate))
    return sorted(paths, key=lambda path: path.as_posix())


def run_git(root: Path, *arguments: str, input_bytes: bytes | None = None) -> bytes:
    process = subprocess.run(
        ["git", *arguments],
        cwd=root,
        input=input_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if process.returncode != 0:
        raise ScanFailure(f"git {' '.join(arguments[:2])} failed")
    return process.stdout


def is_git_repository(root: Path) -> bool:
    process = subprocess.run(
        ["git", "rev-parse", "--is-inside-work-tree"],
        cwd=root,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return process.returncode == 0


def content_findings(content: bytes, relative: Path, prefix: str = "") -> list[tuple[str, str]]:
    path = relative.as_posix()
    findings: list[tuple[str, str]] = []
    if any(pattern.search(content) for pattern in TOKEN_PATTERNS):
        findings.append((f"{prefix}credential-token", path))
    if any(pattern.search(content) for pattern in PATH_PATTERNS):
        findings.append((f"{prefix}absolute-user-path", path))
    if AUTH_TOKEN_KEY.search(content) and not is_schema_path(relative):
        findings.append((f"{prefix}schema-only-auth-token", path))
    return findings


def tracked_size_findings(root: Path) -> list[tuple[str, str]]:
    if not is_git_repository(root):
        return []
    findings: list[tuple[str, str]] = []
    for raw in run_git(root, "ls-files", "-z").split(b"\0"):
        if not raw:
            continue
        relative = Path(os.fsdecode(raw))
        try:
            size = (root / relative).lstat().st_size
        except FileNotFoundError:
            continue
        if size > MAX_TRACKED_BYTES:
            findings.append(("tracked-large-file", relative.as_posix()))
    return findings


def history_findings(root: Path) -> list[tuple[str, str]]:
    if not is_git_repository(root):
        raise ScanFailure("--history requires a Git repository")
    commits = run_git(root, "rev-list", "--all").splitlines()
    seen_pairs: set[tuple[str, bytes]] = set()
    blob_cache: dict[str, tuple[int, bytes | None]] = {}
    findings: list[tuple[str, str]] = []
    for commit_bytes in commits:
        commit = commit_bytes.decode("ascii")
        entries = run_git(root, "ls-tree", "-r", "-z", "--full-tree", commit).split(b"\0")
        for entry in entries:
            if not entry:
                continue
            metadata, separator, path_bytes = entry.partition(b"\t")
            fields = metadata.split()
            if not separator or len(fields) != 3 or fields[1] != b"blob":
                continue
            oid = fields[2].decode("ascii")
            pair = (oid, path_bytes)
            if pair in seen_pairs:
                continue
            seen_pairs.add(pair)
            relative = Path(PurePosixPath(os.fsdecode(path_bytes)))
            if oid not in blob_cache:
                size = int(run_git(root, "cat-file", "-s", oid).strip())
                content = None if size > MAX_TRACKED_BYTES else run_git(
                    root, "cat-file", "blob", oid
                )
                blob_cache[oid] = (size, content)
            size, content = blob_cache[oid]
            if size > MAX_TRACKED_BYTES:
                findings.append(("history-large-blob", relative.as_posix()))
            else:
                assert content is not None
                findings.extend(content_findings(content, relative, "history-"))
            if not relative_allowed(relative):
                findings.append(("history-forbidden-path", relative.as_posix()))
    return findings


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path, nargs="?", default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--paths-from-stdin", action="store_true")
    parser.add_argument("--list-paths", action="store_true")
    parser.add_argument("--history", action="store_true")
    arguments = parser.parse_args()
    root = arguments.root.absolute()
    try:
        metadata = root.lstat()
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            raise ScanFailure("repository root must be a non-symlink directory")
        paths = (
            listed_files(root, "-")
            if arguments.paths_from_stdin
            else canonical_files(root)
        )
        if arguments.list_paths:
            if arguments.history:
                raise ScanFailure("--list-paths and --history cannot be combined")
            for path in paths:
                print(path.as_posix())
            return 0
        findings: list[tuple[str, str]] = []
        for relative in paths:
            findings.extend(content_findings((root / relative).read_bytes(), relative))
        findings.extend(tracked_size_findings(root))
        if arguments.history:
            findings.extend(history_findings(root))
        for finding, path in sorted(set(findings)):
            print(f"{finding}\t{path}")
        return 1 if findings else 0
    except (OSError, UnicodeError, ValueError, ScanFailure) as error:
        print(f"scan failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
