# Build, setup, and removal

This is a source-built personal tool, not a signed/notarized download installer. Read the [release scope](release-scope.md) before enabling monitoring. The historical release record is not a fresh-machine compatibility certificate.

## Requirements

| Dependency | Purpose and boundary |
| --- | --- |
| macOS | Package deployment target is macOS 13. Actual live compatibility must be recorded separately; a deployment target alone is not a tested-version guarantee. |
| Swift 6 or newer and Xcode command-line tools | Build and test. The Swift package has no external package dependencies. |
| Python 3 | Release verification, packaging, update/rollback scripts, and subprocess tests. The update script explicitly uses `/usr/bin/python3`. |
| cmux installed at `/Applications/cmux.app` | The app invokes `/Applications/cmux.app/Contents/Resources/bin/cmux`, not a shell PATH lookup. cmux must be running with compatible topology, visible-screen, and navigation RPCs. |
| Hermes with the terminal UI | Start a supported Hermes version using `hermes --tui` in cmux. Next Up does not install Hermes, choose its model, or configure its provider credentials. |
| macOS notification permission | Required for native notification cards. Speech uses the system synthesizer, not an external voice server. |

Jarvis Bridge is optional completion enrichment. The baseline looks for `~/.local/bin/jarvis-bridge` and `~/dev/jarvis-bridge/config/machines.json`. Without them, it falls back to visible completion text. Do not copy another person's machine registry, credentials, or private bridge data. No bridge setup is required for the limited local support promise.

## Clone and verify

```sh
git clone https://github.com/darelabsai/next-up.git
cd next-up
swift --version
python3 --version
swift test --no-parallel
swift build -c release -Xswiftc -warnings-as-errors
python3 -B -m unittest discover -s Tests/ReleaseToolsTests -v
python3 -B scripts/verify-release-metadata.py
python3 -B scripts/verify-repository-tree.py --history
git diff --check
```

Record `git rev-parse HEAD` with any build report. A source-built binary may differ from the historical accepted executable even when both report 1.2.0 build 3. Do not relabel it as the historical artifact.

## Verify cmux access first

With cmux running:

```sh
/Applications/cmux.app/Contents/Resources/bin/cmux --version
/Applications/cmux.app/Contents/Resources/bin/cmux ping
```

A missing executable means cmux is not at the supported path. Connection refused means the selected socket has no listener; it does not mean Hermes is idle. A permission error is an access prerequisite, not a reason to disable socket authentication.

Follow the installed cmux version's socket-access documentation and Settings. The baseline can read an owner-private capability file at `~/Library/Application Support/NextUp/cmux-capability` and pass it to child CLI calls as `CMUX_SOCKET_CAPABILITY`. It also inherits the launching process's environment. A login-launched app does not inherit arbitrary terminal exports. Capability issuance and password behavior are cmux-version-specific: do not invent a token or put one in Git, a LaunchAgent, a public issue, shell history, or command arguments. If the current cmux version cannot grant the app supported access, stop setup and report the version and sanitized error.

## First installation

Use this only when neither an installed Next Up app nor an existing Next Up LaunchAgent is present. Existing users should use the update section instead. Do not launch a second copy alongside a running monitor.

```sh
test ! -e "$HOME/Applications/Next Up.app"
test ! -e "$HOME/Library/LaunchAgents/ai.darelabs.nextup.plist"
mkdir -p "$HOME/Applications"
scripts/package-local-app.sh --ad-hoc-sign "$HOME/Applications/Next Up.app"
codesign --verify --deep --strict "$HOME/Applications/Next Up.app"
shasum -a 256 "$HOME/Applications/Next Up.app/Contents/MacOS/NextUp"
```

Run the commands individually and stop on any failed check. Packaging refuses an existing destination; it does not install login services or configure agent credentials.

Open `~/Applications/Next Up.app` in Finder. If macOS blocks it, use the normal System Settings > Privacy & Security review for a build you created and trust. Do not disable Gatekeeper globally. An ad-hoc signature checks bundle integrity but does not identify a trusted developer or establish notarization.

Allow notifications when prompted, then inspect System Settings > Notifications > Next Up. Choose banner/alert and sound settings deliberately. Focus modes can hide delivery. In the menu-bar app, select only the intended workspaces and choose Voice Off, Lane Title Only, or Lane + Summary.

The app monitors all workspaces by default, including newly created ones. Use a clean cmux session for initial setup or review workspace selection before starting sensitive work. There is no built-in Hermes process allowlist.

For automatic startup on a fresh installation, add this app in System Settings > General > Login Items. Do not also install a LaunchAgent. This manual login-item path requires a real login acceptance check before claiming automatic startup is verified. Quit through the app menu to stop it. Open the same installed app to start it again.

## Existing LaunchAgent installations and updates

The retained baseline's transactional installer is an **update/rollback tool**, not a first-install bootstrap. It requires an existing installed app and an owner-controlled LaunchAgent. All paths must be absolute, normalized, non-symlinked, owner-controlled, and on the same filesystem. The displaced-app destination must not exist.

Its exact interface is:

```text
scripts/install-local-app.sh install|rollback SOURCE_APP INSTALLED_APP DISPLACED_APP LAUNCH_AGENT EXPECTED_VERSION EXPECTED_BUILD EXPECTED_EXECUTABLE_SHA256
```

Before using it, package a candidate outside the repository, record its executable hash and version/build, and preserve the current app as the rollback target through the installer transaction. Do not hand-copy over a running app. Use the same interface with `rollback`, the saved predecessor as SOURCE_APP, and that predecessor's verified version/build/hash when reverting. Never reuse the candidate hash for the predecessor.

The installer validates source and predecessor before stopping the service, swaps them transactionally, checks signature/hash and one launchd-owned process, and restores the predecessor on a failed acceptance step. It does not prove notifications or Hermes detection; those remain live checks. Installer tests use fake system commands and do not count as a real install receipt.

For a verified existing LaunchAgent, restart via:

```sh
launchctl kickstart -k "gui/$(id -u)/ai.darelabs.nextup"
```

Do not run this for a manual/Login Items installation with no such service.

## Privacy, diagnostics, and limitations

- Next Up reads the bounded visible terminal screen, not only metadata. Lane names and completion summaries can appear in notifications, speech, and persistent state.
- Input-required notifications avoid prompt contents and secrets. This does not make all stored completion state content-free.
- The `--probe` command can expose lane titles and summaries. Do not post its raw output publicly. Use neutral disposable sessions for reports.
- Viewport cropping, upstream renderer changes, and prompts appearing between polls can cause missed detection. Gray means unrecognized, not proof that the agent is idle.
- Regular Terminal sessions, non-TUI Hermes, other agents, and universal session discovery are outside this release's support promise.
- Terminal content shaped exactly like supported controls can be mistaken for live controls. This is observational sensing, not authenticated lifecycle events.
- Basic monitoring does not need Accessibility permission. Do not grant it merely to fix a socket error. Separate UI-test automation may request its own permission.

Settings and state live under `~/Library/Application Support/NextUp`. Existing LaunchAgent installations may log to `~/Library/Logs/NextUp.log` and `NextUp.error.log`. Treat both as private. Send only a sanitized error, app version/build, cmux/Hermes versions, and reproduction steps in a public issue.

## Uninstall without deleting personal state

1. Quit Next Up.
2. If configured through Login Items, remove that entry in System Settings.
3. For an existing LaunchAgent installation, unload it with `launchctl bootout "gui/$(id -u)/ai.darelabs.nextup"`. Confirm the service is stopped, then move its exact plist out of `~/Library/LaunchAgents` into a private backup folder.
4. Confirm no NextUp process remains with `pgrep -fl NextUp`. Do not kill unrelated processes by a broad name match.
5. Move the installed app to Trash using Finder. Keep any verified rollback artifact private.
6. Leave `~/Library/Application Support/NextUp` and logs intact by default. They may contain alert content and a socket capability. Delete them only if you intentionally want to erase preferences, pending acknowledgments, and local credentials. Do not upload them.

Do not remove cmux, Hermes, their settings, or other agent sessions when uninstalling Next Up.
