# Next Up Release Catalog

`catalog.json` is the canonical machine-readable release catalog. `VERSION`, `packaging/Info.plist`, `CHANGELOG.md`, this table, and every release record are checked together by `python3 -B scripts/verify-release-metadata.py`.

| Version | Date | Bundle build | Status | Record |
|---|---|---:|---|---|
| 1.1.0 | 2026-08-08 | 2 | live-accepted | [Next Up 1.1.0](1.1.0.md) |
| 1.0.0 | 2026-08-08 | 1 | live-accepted | [Next Up 1.0.0](1.0.0.md) |

## Lifecycle

`planned` → `implemented` → `reviewed` → `source-verified` → `packaged` → `deployed` → `live-accepted` → `superseded`

A release can remain at an earlier state when a later gate is blocked. Deployment and native acceptance are never inferred from tests or fixtures.
