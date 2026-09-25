# Limited public release contract

## Goal and baseline

Make the existing Next Up 1.2.0 build 3 behavior reproducible as a personal macOS notification tool for Hermes `--tui` sessions visible in cmux. Source baseline: `87b501e06413a12449be7d05a4293f7f40dc80e5`; implementation: `256f0117a70b0fb293df8cfd3ee53065c0b9374a`. This is release preparation, not a new agent-monitoring architecture.

The historical [1.2 acceptance record](releases/1.2.0.md) describes one installed artifact. It is not evidence that a new build or a newer cmux/Hermes combination has passed live acceptance.

## Supported product boundary

- A single Mac running cmux at `/Applications/cmux.app`, with CLI/socket access available to the app's login-session process.
- Hermes terminal UI launched with `hermes --tui` inside selected cmux workspaces, with enough visible rows/columns to render supported controls.
- Workspace selection, current status, completion and input-required notifications, optional speech, acknowledgment, and exact-identity navigation as implemented in the baseline.
- Screen observation, not native Hermes lifecycle subscriptions. No promise of monitoring sessions outside cmux, every profile, background automation, or every prompt between polls.

This boundary is a support promise, not an executable whitelist. The baseline classifies visible terminal structure and does not prove every matched pane belongs to Hermes. Select only intended workspaces. Do not represent it as secure identification of an agent process.

Retained SSH surfaces and Jarvis Bridge completion enrichment already exist. Preserve their code and fallbacks, but do not make remote hosts, private bridge configuration, or another agent mandatory for the basic local setup. They are outside this release's minimum acceptance claim.

## Behavior that must remain unchanged

- Input controls take precedence over working/ready interpretation. Titles are hints, not sufficient evidence of a pending input request.
- Completion requires the existing observed working-to-ready transition. Starting the monitor on an idle pane must not manufacture completion.
- Preserve workspace exclusions, voice modes, acknowledgment, repeat cadence, and restart persistence.
- Preserve focused suppression, later-focus clearing, and fresh identity validation on notification navigation.
- Monitoring never types, answers, approves, or resumes an agent. Explicit notification clicks may focus cmux.
- Missing or ambiguous routes must not send a user to a different session.

## Privacy disclosure

The existing app reads bounded visible terminal content. Completion text, lane titles, and optional read-only Hermes turn enrichment can contribute to notifications, speech, and stored alert state. It is not a metadata-only observer. Do not use sensitive panes for a public demonstration or publish live captures.

Input-required alerts use generic interaction-specific wording rather than prompt/choice/secret contents. Credentials and cmux capability material belong outside Git. Basic local monitoring does not require an external model service. Optional bridge configuration can involve remote reads and must be disclosed separately.

## Evidence required before release approval

1. Full deterministic tests, warning-as-error release build, release metadata checks, privacy/history scan, and exact-head hosted CI pass.
2. Independent review covers the actual candidate tree; changes after review require appropriate re-review.
3. A fresh checkout can follow the documented dependency, build, setup, stop, rollback, and removal instructions. Record what is tested, including any mocked installer commands.
4. Package receipt identifies exact source commit/tree, version/build, executable hash, architecture, and signing mode. A rebuilt binary is not the historical artifact merely because its version matches.
5. Isolated real Hermes activity in cmux proves working, input-required, resolution, and completion through the actual installed pipeline. Verify focused suppression, later-focus clearing, notification navigation, acknowledgment, and restart behavior without disturbing unrelated sessions.
6. Native card delivery/removal and owner interaction require direct observation. Unit tests, printed fake prompts, synthetic fixtures, and historical acceptance are not substitutes.
7. Test sessions, observers, and temporary resources are cleaned up. The working app has a verified rollback path.

No claim of reliability across all upstream versions follows from one tested combination. Publish the actual tested versions and known sampling/viewport limitations.

## Explicit non-goals and approval boundary

No Claude Code, Codex, Grok Build, universal session discovery, multi-machine redesign, payment system, or Next Up 2 rewrite. No arbitrary refactoring for hypothetical adapters. Fix only release-blocking defects and maintain behavior with regression tests.

Public source availability is not a signed/notarized app release and does not choose an open-source license. License selection, a release tag, uploaded binary assets, and release announcement remain subject to owner approval. Stop with an evidence-backed candidate; do not change historical acceptance fields to make a new candidate appear accepted.
