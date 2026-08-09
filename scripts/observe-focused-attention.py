#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

MAX_PROBE_OUTPUT = 16_384
DEFAULT_APP_EXECUTABLE = Path.home() / "Applications" / "Next Up.app" / "Contents" / "MacOS" / "NextUp"


class ObserverFailure(Exception):
    pass


def run_probe(executable: Path, argument: str, payload: object | str) -> dict[str, object]:
    encoded = payload.encode() if isinstance(payload, str) else json.dumps(
        payload, sort_keys=True, separators=(",", ":")
    ).encode()
    try:
        result = subprocess.run(
            [str(executable), argument],
            input=encoded,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ObserverFailure("probe failed") from error
    if result.returncode != 0 or not result.stdout or len(result.stdout) > MAX_PROBE_OUTPUT:
        raise ObserverFailure("probe failed")
    try:
        decoded = json.loads(result.stdout)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ObserverFailure("probe failed") from error
    if not isinstance(decoded, dict):
        raise ObserverFailure("probe failed")
    return decoded


def complete_candidate(candidate: object, kind: str, lane_id: str) -> dict[str, object] | None:
    if not isinstance(candidate, dict) or candidate.get("kind") != kind or candidate.get("laneID") != lane_id:
        return None
    route = candidate.get("navigationTarget")
    if not isinstance(route, dict):
        return None
    if any(not isinstance(route.get(key), str) or not route[key] for key in (
        "windowID", "workspaceID", "paneID", "surfaceID"
    )):
        return None
    return {
        "kind": kind,
        "laneID": lane_id,
        "navigationTarget": {
            "windowID": route["windowID"],
            "workspaceID": route["workspaceID"],
            "paneID": route["paneID"],
            "surfaceID": route["surfaceID"],
        },
    }


def atomic_write(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def nonnegative_int(value: object) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lane-id", required=True)
    parser.add_argument("--kind", choices=("completion", "input-required"), required=True)
    parser.add_argument(
        "--acceptance-case",
        choices=("focused-suppression", "later-focus-auto-clear"),
        default="focused-suppression",
    )
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument("--poll-interval", type=float, default=0.5)
    parser.add_argument("--app-executable", type=Path, default=DEFAULT_APP_EXECUTABLE)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    if not arguments.lane_id or arguments.timeout <= 0 or arguments.poll_interval <= 0:
        raise ObserverFailure("invalid arguments")
    executable = arguments.app_executable
    if not executable.is_absolute() or executable.is_symlink() or not executable.is_file():
        raise ObserverFailure("invalid executable")

    kind = "inputRequired" if arguments.kind == "input-required" else "completion"
    deadline = time.monotonic() + arguments.timeout
    initial = run_probe(executable, "--alert-list-probe", arguments.lane_id + "\n")
    readiness = initial.get("readiness")
    if not isinstance(readiness, dict):
        raise ObserverFailure("missing readiness")
    readiness_epoch = readiness.get("processEpoch")
    readiness_sequence = nonnegative_int(readiness.get("appliedPollSequence"))
    readiness_baseline = nonnegative_int(readiness.get("appliedBaselineGeneration"))
    if not isinstance(readiness_epoch, str) or readiness_sequence is None or readiness_baseline is None:
        raise ObserverFailure("missing readiness")
    required_baseline = readiness_baseline + (
        2 if arguments.acceptance_case == "later-focus-auto-clear" else 0
    )

    pending_true_observed = False
    latest_alerts = initial
    while time.monotonic() < deadline:
        matched_candidates: list[dict[str, object]] = []
        candidates = latest_alerts.get("candidates")
        if isinstance(candidates, list):
            for item in candidates:
                candidate = complete_candidate(item, kind, arguments.lane_id)
                if candidate is not None:
                    matched_candidates.append(candidate)
        for candidate in matched_candidates:
            focused = run_probe(
                executable,
                "--focused-lane-probe",
                {
                    "candidate": candidate,
                    "readiness": {
                        "processEpoch": readiness_epoch,
                        "appliedPollSequence": readiness_sequence,
                        "appliedBaselineGeneration": readiness_baseline,
                    },
                },
            )
            authoritative_pending = focused.get("authoritativePending")
            if authoritative_pending is True:
                pending_true_observed = True
            current_epoch = focused.get("processEpoch")
            applied_sequence = nonnegative_int(focused.get("appliedPollSequence"))
            baseline_generation = nonnegative_int(focused.get("appliedBaselineGeneration"))
            receipt_sequence = nonnegative_int(focused.get("acceptedReceiptSequence"))
            receipt_is_valid = (
                focused.get("receiptAccepted") is True
                and current_epoch == readiness_epoch
                and applied_sequence is not None
                and receipt_sequence is not None
                and receipt_sequence > readiness_sequence
                and receipt_sequence <= applied_sequence
            )
            focus_is_exact = (
                focused.get("exactlyFocused") is True
                and focused.get("cmuxFrontmost") is True
            )
            baseline_is_ready = (
                baseline_generation is not None
                and baseline_generation >= required_baseline
            )
            if arguments.acceptance_case == "focused-suppression":
                case_is_satisfied = focus_is_exact and receipt_is_valid and baseline_is_ready
            else:
                case_is_satisfied = (
                    pending_true_observed
                    and authoritative_pending is False
                    and focus_is_exact
                    and receipt_is_valid
                    and baseline_is_ready
                )
            if case_is_satisfied:
                route = candidate["navigationTarget"]
                assert isinstance(route, dict)
                assert applied_sequence is not None
                assert baseline_generation is not None
                assert receipt_sequence is not None
                atomic_write(arguments.output, {
                    "schema": 2,
                    "acceptance_case": arguments.acceptance_case,
                    "kind": kind,
                    "lane_id": arguments.lane_id,
                    "route_ids": {
                        "window": route["windowID"],
                        "workspace": route["workspaceID"],
                        "pane": route["paneID"],
                        "surface": route["surfaceID"],
                    },
                    "readiness": {
                        "processEpoch": readiness_epoch,
                        "appliedPollSequence": readiness_sequence,
                        "appliedBaselineGeneration": readiness_baseline,
                    },
                    "accepted_receipt_sequence": receipt_sequence,
                    "observed_applied_sequence": applied_sequence,
                    "observed_baseline_generation": baseline_generation,
                    "required_baseline_generation": required_baseline,
                    "process_epoch": current_epoch,
                    "exactly_focused": True,
                    "cmux_frontmost": True,
                    "receipt_accepted": True,
                    "pending_true_observed": pending_true_observed,
                    "authoritative_pending_after": authoritative_pending is True,
                })
                return 0
        time.sleep(arguments.poll_interval)
        latest_alerts = run_probe(executable, "--alert-list-probe", arguments.lane_id + "\n")
    raise ObserverFailure("timed out")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ObserverFailure as error:
        if str(error) == "timed out":
            print("focused attention observer timed out", file=sys.stderr)
        else:
            print("focused attention observer failed", file=sys.stderr)
        raise SystemExit(1)
