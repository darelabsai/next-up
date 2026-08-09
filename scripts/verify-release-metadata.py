#!/usr/bin/env python3
from __future__ import annotations

import json
import plistlib
import re
import sys
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SEMVER = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
HUMAN_CATALOG_ROW = re.compile(
    r"^\| (?P<version>\d+\.\d+\.\d+) \| "
    r"(?P<date>\d{4}-\d{2}-\d{2}) \| "
    r"(?P<build>[1-9]\d*) \| "
    r"(?P<status>[a-z-]+) \| "
    r"\[[^]\r\n]+\]\((?P<record>[^()\r\n]+)\) \|$"
)
STATUSES = (
    "planned",
    "implemented",
    "reviewed",
    "source-verified",
    "packaged",
    "deployed",
    "live-accepted",
    "superseded",
)
TOP_KEYS = {"schema_version", "releases"}
RELEASE_KEYS = {
    "version",
    "date",
    "build",
    "status",
    "source_commit",
    "artifact_sha256",
    "signing_mode",
    "deployment_identity",
    "predecessor",
    "rollback_target",
    "historical_bundle_version",
    "historical_bundle_build",
    "record",
}
RECORD_LABELS = (
    "Version",
    "Build",
    "Date",
    "Status",
    "Source-Commit",
    "Artifact-SHA256",
    "Predecessor",
    "Rollback-Target",
)


def fail(errors: list[str], message: str) -> None:
    errors.append(message)


def nullable_text(value: object) -> str:
    return "null" if value is None else str(value)


def parse_record(path: Path, errors: list[str]) -> dict[str, str]:
    if not path.is_file():
        fail(errors, f"missing release record: {path.relative_to(ROOT)}")
        return {}
    lines = path.read_text(encoding="utf-8").splitlines()
    parsed: dict[str, str] = {}
    for index, label in enumerate(RECORD_LABELS):
        prefix = f"{label}: "
        if index >= len(lines) or not lines[index].startswith(prefix):
            fail(errors, f"{path.relative_to(ROOT)} line {index + 1} must start with {prefix!r}")
            continue
        parsed[label] = lines[index][len(prefix):]
    return parsed


def parse_human_catalog(text: str, errors: list[str]) -> dict[str, dict[str, object]]:
    parsed: dict[str, dict[str, object]] = {}
    for line_number, line in enumerate(text.splitlines(), start=1):
        if not line.startswith("| ") or line.startswith("| Version "):
            continue
        match = HUMAN_CATALOG_ROW.fullmatch(line)
        if match is None:
            fail(errors, f"human release catalog row {line_number} is malformed")
            continue
        values = match.groupdict()
        version = values["version"]
        if version in parsed:
            fail(errors, f"human release catalog has duplicate version: {version}")
            continue
        parsed[version] = {
            "version": version,
            "date": values["date"],
            "build": int(values["build"]),
            "status": values["status"],
            "record": values["record"],
        }
    return parsed


def main() -> int:
    errors: list[str] = []

    version_path = ROOT / "VERSION"
    version_text = version_path.read_text(encoding="utf-8") if version_path.is_file() else ""
    version_lines = version_text.splitlines()
    current_version = version_lines[0] if len(version_lines) == 1 else ""
    if not SEMVER.fullmatch(current_version):
        fail(errors, "VERSION must contain exactly one SemVer core line")

    plist_path = ROOT / "packaging" / "Info.plist"
    try:
        with plist_path.open("rb") as handle:
            plist = plistlib.load(handle)
    except Exception as exc:  # noqa: BLE001
        fail(errors, f"cannot parse packaging/Info.plist: {type(exc).__name__}")
        plist = {}
    plist_version = plist.get("CFBundleShortVersionString")
    plist_build_text = str(plist.get("CFBundleVersion", ""))
    if plist_version != current_version:
        fail(errors, "Info.plist short version does not equal VERSION")
    if not re.fullmatch(r"[1-9]\d*", plist_build_text):
        fail(errors, "Info.plist bundle build must be a positive integer")
    plist_build = int(plist_build_text) if plist_build_text.isdigit() else 0

    catalog_path = ROOT / "docs" / "releases" / "catalog.json"
    try:
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        fail(errors, f"cannot parse docs/releases/catalog.json: {type(exc).__name__}")
        catalog = {}
    if set(catalog) != TOP_KEYS:
        fail(errors, "catalog top-level keys must match the closed schema")
    if catalog.get("schema_version") != 1:
        fail(errors, "catalog schema_version must be 1")
    releases = catalog.get("releases")
    if not isinstance(releases, list) or not releases:
        fail(errors, "catalog releases must be a non-empty array")
        releases = []

    changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8") if (ROOT / "CHANGELOG.md").is_file() else ""
    human_catalog = (ROOT / "docs" / "releases" / "README.md").read_text(encoding="utf-8") if (ROOT / "docs" / "releases" / "README.md").is_file() else ""
    changelog_versions = set(re.findall(r"^## \[([^]]+)\] - \d{4}-\d{2}-\d{2}$", changelog, re.MULTILINE))
    human_releases = parse_human_catalog(human_catalog, errors)
    human_versions = set(human_releases)
    seen: set[str] = set()
    catalog_versions: set[str] = set()
    current_release: dict[str, object] | None = None

    for index, release in enumerate(releases):
        where = f"catalog release[{index}]"
        if not isinstance(release, dict) or set(release) != RELEASE_KEYS:
            fail(errors, f"{where} keys must match the closed schema")
            continue
        version = release["version"]
        if not isinstance(version, str) or not SEMVER.fullmatch(version):
            fail(errors, f"{where} version is not SemVer core")
            continue
        if version in seen:
            fail(errors, f"duplicate catalog version: {version}")
        seen.add(version)
        catalog_versions.add(version)
        if version == current_version:
            current_release = release
        try:
            date.fromisoformat(release["date"])
        except (TypeError, ValueError):
            fail(errors, f"{where} date must be ISO YYYY-MM-DD")
        if not isinstance(release["build"], int) or isinstance(release["build"], bool) or release["build"] <= 0:
            fail(errors, f"{where} build must be a positive integer")
        if release["status"] not in STATUSES:
            fail(errors, f"{where} has an invalid lifecycle status")
        for key in ("predecessor", "rollback_target", "historical_bundle_version"):
            value = release[key]
            if value is not None and (not isinstance(value, str) or not SEMVER.fullmatch(value)):
                fail(errors, f"{where} {key} must be SemVer or null")
        historical_build = release["historical_bundle_build"]
        if historical_build is not None and (not isinstance(historical_build, int) or isinstance(historical_build, bool) or historical_build <= 0):
            fail(errors, f"{where} historical_bundle_build must be positive integer or null")
        source_commit = release["source_commit"]
        if source_commit is not None and (not isinstance(source_commit, str) or not COMMIT.fullmatch(source_commit)):
            fail(errors, f"{where} source_commit must be 40 lowercase hex characters or null")
        artifact = release["artifact_sha256"]
        if artifact is not None and (not isinstance(artifact, str) or not SHA256.fullmatch(artifact)):
            fail(errors, f"{where} artifact_sha256 must be 64 lowercase hex characters or null")
        for key in ("signing_mode", "deployment_identity"):
            if release[key] is not None and (not isinstance(release[key], str) or not release[key]):
                fail(errors, f"{where} {key} must be non-empty string or null")
        receipt_requirements = {
            "source-verified": ("source_commit",),
            "packaged": ("source_commit", "artifact_sha256", "signing_mode"),
            "deployed": (
                "source_commit",
                "artifact_sha256",
                "signing_mode",
                "deployment_identity",
            ),
            "live-accepted": (
                "source_commit",
                "artifact_sha256",
                "signing_mode",
                "deployment_identity",
            ),
            "superseded": (
                "source_commit",
                "artifact_sha256",
                "signing_mode",
                "deployment_identity",
            ),
        }
        for required in receipt_requirements.get(release["status"], ()):
            if release[required] is None:
                fail(errors, f"status {release['status']} requires {required}")
        record_value = release["record"]
        expected_record = f"docs/releases/{version}.md"
        if record_value != expected_record:
            fail(errors, f"{where} record must equal {expected_record}")
        record = parse_record(ROOT / expected_record, errors)
        expected_lines = {
            "Version": version,
            "Build": str(release["build"]),
            "Date": str(release["date"]),
            "Status": str(release["status"]),
            "Source-Commit": nullable_text(source_commit),
            "Artifact-SHA256": nullable_text(artifact),
            "Predecessor": nullable_text(release["predecessor"]),
            "Rollback-Target": nullable_text(release["rollback_target"]),
        }
        for label, expected in expected_lines.items():
            if record.get(label) != expected:
                fail(errors, f"{expected_record} {label} does not match catalog")
        if f"## [{version}] - {release['date']}" not in changelog:
            fail(errors, f"CHANGELOG missing exact heading for {version}")
        human_release = human_releases.get(version)
        if human_release is None:
            fail(errors, f"human release catalog missing row for {version}")
        else:
            human_expected = {
                "date": release["date"],
                "build": release["build"],
                "status": release["status"],
                "record": f"{version}.md",
            }
            for field, expected in human_expected.items():
                if human_release[field] != expected:
                    fail(errors, f"human catalog {field} does not match catalog for {version}")

    if current_release is None:
        fail(errors, "catalog has no entry matching VERSION")
    else:
        if current_release["build"] != plist_build:
            fail(errors, "current catalog build does not equal Info.plist build")

    if catalog_versions != changelog_versions:
        fail(errors, "catalog and CHANGELOG release sets differ")
    if catalog_versions != human_versions:
        fail(errors, "machine and human catalog release sets differ")
    release_files = {p.stem for p in (ROOT / "docs" / "releases").glob("*.md") if p.name != "README.md"}
    if release_files != catalog_versions:
        fail(errors, "catalog and versioned release-record file sets differ")

    release_100 = next((item for item in releases if isinstance(item, dict) and item.get("version") == "1.0.0"), None)
    if not release_100 or release_100.get("historical_bundle_version") != "0.1.0" or release_100.get("historical_bundle_build") != 1:
        fail(errors, "1.0.0 must preserve historical bundle version 0.1.0/build 1")

    if errors:
        for error in errors:
            print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(f"PASS: release metadata synchronized for {current_version} build {plist_build} ({len(releases)} releases)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
