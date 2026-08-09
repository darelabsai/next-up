# Changelog

All notable Next Up releases are recorded here. Detailed implementation, verification, deployment, and acceptance receipts live in `docs/releases/`.

## [1.1.0] - 2026-08-08

### Added

- Notification-body navigation to the freshest exact CMUX window, workspace, pane, and surface identity available.
- A machine-readable release catalog and synchronized release metadata gate.

### Changed

- Completion and input reminders repeat after increasing 5, 10, 20, 40, and 80 minute gaps instead of every 150 seconds.
- Elapsed ages over one hour use natural hour-and-minute wording.

### Safety

- Notification-body clicks navigate and acknowledge; **Mark Seen** acknowledges without navigating.
- Notification routing carries opaque CMUX identifiers only and fails closed on stale or ambiguous identity.

## [1.0.0] - 2026-08-08

### Added

- Local-first CMUX lane monitoring, completion alerts, input-required attention, session grounding, notification history, and bounded announcement summaries.

### Historical metadata

- The 1.0.0 product line shipped with bundle version `0.1.0` and build `1` before semantic release metadata was established.
