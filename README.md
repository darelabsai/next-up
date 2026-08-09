# Next Up

A local macOS menu-bar attention monitor for Hermes agents running in CMUX.

## What it is for

Next Up lets you step away from active agent sessions without repeatedly checking every terminal. It watches selected CMUX workspaces, shows which lanes are working or waiting, and calls attention to the two moments that require you: an agent needs input, or a previously working agent has finished.

The app is observational while monitoring. It reads CMUX topology and visible terminal content, enriches completed work from Hermes through the read-only Jarvis Bridge, and presents the result through a compact menu-bar popover, native macOS notifications, and optional speech. It never types into panes, approves requests, resumes agents, or sends gateway messages. A deliberate click on a Next Up notification can activate CMUX and focus the freshly validated window, workspace, pane, and surface for that alert.

The deployed version monitors CMUX-visible lanes on this MacBook Air plus exact retained-SSH Mac Mini surfaces. It is not yet a universal inventory of every Hermes CLI, gateway, cron, or subagent run; that proposed future direction is documented separately below.

## 1.2 candidate scope

Version 1.2.0 build 3 is a reviewed candidate, not a deployed or live-accepted release. Its closed acceptance contract separately covers focused suppression and later-focus auto-clear for completion and input-required alerts, body-click route plus foreground, owner verification that native cards are removed, and cleanup. Clicking a notification body foregrounds CMUX and navigates using freshly revalidated exact identity.

Those statements define candidate behavior to verify. They do not claim measured event latency, universal live acceptance, Hermes-only gating, source verification, artifact identity, or deployment; every exact 1.2 interaction receipt remains pending in the release record.

## Installed behavior

- Performs an authoritative CMUX inventory and bounded 80-row visible-screen read every 5 seconds. A cheap topology/title-only scan runs every second for selected workspaces and can wake a coalesced screen read when a lane title begins with `⚠` or `⚠️`.
- Watches every workspace by default, including workspaces created after Next Up starts; use the checkable workspace menu to exclude any you do not want watched.
- Persists explicit exclusions in `~/Library/Application Support/NextUp/workspace-selection.json`.
- Reads each terminal surface's current visible screen (no scrollback) to classify status; visible structural controls are authoritative. Warning titles can only trigger or corroborate a read and never establish **Needs input** by themselves. Monitoring never sends terminal input, changes focus, or writes to Hermes sessions/gateways; only an explicit notification-body click invokes the bounded navigation path described below.
- Distinguishes **Working**, **Needs input**, **Waiting**, and unknown states. It structurally recognizes Hermes Approval, Clarify choices, Clarify free text, Confirm, sudo-password, and secret-input controls. Confirm does not produce a Hermes warning title, so it is detected by the ordinary five-second authoritative read. Rotating active footers such as `analyzing…`, `mulling…`, and `ruminating…` retain working-state precedence unless source-shaped actionable controls are present.
- Creates an alert only on an observed `busy → ready` edge.
- Announces input-required states immediately, then after 5, 10, 20, 40, and 80 minutes, continuing to double to a safe persisted-count ceiling until acknowledged or resolved. These cards are Time Sensitive; ordinary completions use the standard active interruption level.
- Uses privacy-safe, interaction-specific input announcements: **“Heads up. _Lane_ needs your approval.”** for approval/permission controls, **“Heads up. _Lane_ has a question for you.”** for interactive Clarify controls, and **“Heads up. _Lane_ is waiting for your response.”** for Confirm, sudo, secret, and other corroborated response controls. Status ornaments such as `⚠️` are removed from spoken and notification titles. Input-required screens are classified before completion extraction, session discovery, transcript retrieval, or enrichment; prompt text, choice labels, snippets, summaries, and transcript content never enter input alerts.
- Recognition is observational rather than event-sourced: a prompt can still be missed if it appears and disappears between authoritative reads without a warning-title transition, or if required structure is truncated/offscreen. Terminal zoom and short pane geometry are part of this boundary. In a controlled live CMUX test, the same pending Hermes approval classified as **Needs input** in a 209×54-cell viewport but as unknown in a 209×11-cell viewport; the small render left stale outer-border cells after approval rows, so the deliberately strict matched-border parser failed closed. Zooming out or enlarging the pane restores recognition. Conversely, a byte-identical complete source-shaped historical reproduction in the accepted visible region cannot be distinguished from a live prompt.
- Speaks immediately, then after increasing 5, 10, 20, 40, and 80-minute gaps that continue doubling to a safe ceiling until the completion is acknowledged. Repeat speech includes the lane's rounded-up idle age with natural minute/hour wording, such as “1 minute” or “an hour and 13 minutes.”
- Groups simultaneous spoken completions by workspace and uses smooth wording without a `Summary:` label.
- Resolves each persistent CMUX surface once to a unique machine/profile-scoped Hermes session using title plus bounded visible content, then stores the binding in `~/Library/Application Support/NextUp/session-bindings.json`.
- Retrieves the latest complete Hermes turn read-only on completion, compresses it to at most nine words, and falls back to the completed pane's visible response whenever resolution, SSH, retrieval, or compression fails.
- Supports local Mac Air sessions and exact retained-SSH Mac Mini surfaces through Jarvis Bridge; visible snippets are passed through bounded stdin, never process arguments.
- Posts native macOS notifications whose body click navigates to the alert's freshly revalidated CMUX location as deeply as current identifiers safely permit and marks that alert seen. Persistent UUID misses fail closed rather than falling through to potentially reused references. Repeated notifications replace the prior card for that lane instead of stacking duplicates. Banner versus persistent Alert presentation remains the user's per-app macOS setting.
- **Mark Seen** acknowledges without navigating. An alert is also acknowledged by clicking its notification body, clicking its **×** in the menu-bar popover, clicking **Clear Alerts**, or by the lane becoming busy again (which means someone responded/restarted work).
- State persists in `~/Library/Application Support/NextUp/state.json`.
- A CMUX capability is stored locally at `~/Library/Application Support/NextUp/cmux-capability` with mode `0600`; it is never committed or embedded in the app/LaunchAgent.

## UI

Click the high-contrast bell in the macOS menu bar. The workspace menu shows the selected/available count and lets you check or uncheck multiple workspaces. The voice menu persists **Voice Off**, **Lane Title Only**, or **Lane + Summary**. Lanes are grouped by workspace and ordered by urgent input, pending completion, current work, and recent activity: red means **Needs input**, orange means **Working**, green means **Waiting**, and gray is unrecognized. Escape and outside click dismiss the taller transient popover.

Voice Off disables spoken speech only; native cards and their notification sounds remain enabled. There is intentionally no summary-only speech mode.

## Starting and stopping

The installed LaunchAgent starts Next Up once at login. Choosing **Quit** intentionally leaves it stopped. Start it again by opening `~/Applications/Next Up.app` in Finder/Spotlight, or run:

```bash
launchctl kickstart -k "gui/$(id -u)/ai.darelabs.nextup"
```

On startup it rediscovers CMUX workspaces and resumes the saved selection policy; it is no longer tied to a particular workspace reference.

## Build and test

```bash
swift test
python3 -B -m unittest -v Tests.ReleaseToolsTests.test_package_local_app
python3 -B scripts/verify-release-metadata.py
swift run NextUp --probe
swift run NextUp --announcement-probe
swift build -c release -Xswiftc -warnings-as-errors
scripts/package-local-app.sh --ad-hoc-sign /tmp/Next-Up-candidate.app
```

The live probe prints monitored lanes as JSON. The announcement probe prints deterministic approval, clarification, response, and mixed presentation fixtures. Both exit without starting the UI; the announcement probe also avoids CMUX, speech, and notification side effects. Installed acceptance additionally uses bounded stdin-only navigation, pending, alert-list, and focused-lane probes. Focus acceptance exposes authoritative pending state and CMUX-frontmost state as separate booleans, plus opaque route IDs and monotonic counters; it never emits lane content. The observer can prove focused suppression before durable pending visibility or a pending true→false later-focus transition after two successful baseline generations.

## Installed paths

- App: `~/Applications/Next Up.app`
- LaunchAgent: `~/Library/LaunchAgents/ai.darelabs.nextup.plist`
- Logs: `~/Library/Logs/NextUp.log` and `~/Library/Logs/NextUp.error.log`
- Session bindings: `~/Library/Application Support/NextUp/session-bindings.json`
- Voice preferences: `~/Library/Application Support/NextUp/voice-preferences.json`
- Activity ordering: `~/Library/Application Support/NextUp/activity-dates.json`

## Design and implementation history

The durable release catalog is [`docs/releases/README.md`](docs/releases/README.md), backed by machine-validated [`docs/releases/catalog.json`](docs/releases/catalog.json), per-release verification records, and [`CHANGELOG.md`](CHANGELOG.md), so release truth does not depend on raw Git history. The accepted reliability, session-grounding, notification, voice, UI, and verification requirements are recorded in [`docs/plans/2026-08-05-next-up-reliability-and-session-grounding.md`](docs/plans/2026-08-05-next-up-reliability-and-session-grounding.md). The investigated input-recognition incident and its unresolved sampling/classifier uncertainty are documented in [`docs/research/2026-08-07-hermes-input-state-recognition.md`](docs/research/2026-08-07-hermes-input-state-recognition.md); the independently approved implementation contract is [`docs/plans/2026-08-07-generalize-hermes-input-recognition.md`](docs/plans/2026-08-07-generalize-hermes-input-recognition.md). The layered CMUX, retained-screen, SSH, and ICMP evidence from an observed Mac Mini outage is recorded in [`docs/research/2026-08-08-mac-mini-unreachable-observation.md`](docs/research/2026-08-08-mac-mini-unreachable-observation.md), with a machine-readable companion at [`docs/research/2026-08-08-mac-mini-unreachable-evidence.json`](docs/research/2026-08-08-mac-mini-unreachable-evidence.json). A proposed, not-yet-authorized migration from CMUX-only inference to a universal event-driven Hermes attention ledger is preserved separately in [`docs/plans/2026-08-06-universal-hermes-attention-backend.md`](docs/plans/2026-08-06-universal-hermes-attention-backend.md).

## VoiceBox

The first version uses macOS `NSSpeechSynthesizer` so alerts have no model startup or server dependency. VoiceBox can later replace the announcer via its local `POST /speak` API at `127.0.0.1:17493`; keeping that optional prevents a stopped VoiceBox app from breaking completion detection.
