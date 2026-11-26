# Agent instructions

These instructions apply throughout this repository.

## Project

`scalectl` is a native macOS CLI for inspecting and selecting display modes and requesting additional scaled/HiDPI modes through display-model overrides. Swift Package Manager builds it with Swift 6+, Apple Command Line Tools, and system frameworks only.

- `Sources/scalectl/main.swift`: command parsing, Core Graphics calls, output.
- `Sources/ScaleCore/Overrides.swift`: mode encoding, merging, backup/restore, filesystem protections.
- `Sources/ScaleCore/Confirmation.swift`: timed confirmation using a monotonic deadline.
- `Sources/TerminalIO`: small C bridge for terminal readiness via `select`.
- `Tests/ScaleCoreTests`: standalone checks; does not require XCTest or full Xcode.
- `scripts`: build, smoke checks and release packaging.
- `.github/workflows`: macOS CI and version-tag releases.

## Build and validate

```sh
./scripts/build.sh
./scripts/check.sh
```

Checks must not change real display modes or write system overrides. Use isolated temporary fixtures. Never run `add --apply`, `restore --apply`, `set` with a different mode, or reboot as part of automated validation. Live display changes require explicit user authorization.

## Implementation constraints

- Preserve unrelated override keys and existing modes, and back up original bytes and permissions before installation. Refuse conflicting edits made by other tools.
- Keep fixed system paths, ownership/permission validation, symlink/hardlink protection, operation locking and recoverable installation ordering.
- Ordinary display inspection and mode selection must not require root. Only installing/restoring system overrides requires it.
- Native overrides affect every display with the same vendor/product identity. macOS decides whether requested sizes are available; do not promise acceptance.
- Override records are undocumented. Document platform assumptions and distinguish logical dimensions, rendering pixels and physical panel resolution.
- Keep confirmation rollback enabled. On macOS, `poll` on `/dev/tty` can return `POLLNVAL` immediately; retain the `select` bridge and terminal regression check.
- Report input errors separately from timeouts. Never weaken rollback to conceal an error.
- Avoid third-party runtime dependencies, privileged daemons, SIP changes and automatic reboot/reinitialization.

## Releases and documentation

- Keep README examples generic: no personal filesystem paths, device UUIDs or machine-specific state.
- Update help and README when adding commands; preserve JSON output compatibility where possible.
- Pin GitHub Actions to full commit SHAs and disable checkout credential persistence. Give only the publishing job `contents: write`; never execute pull-request code with write credentials.
- Version tags (`vMAJOR.MINOR.PATCH`, optionally with a prerelease suffix) trigger releases. Do not create/push tags, publish releases, or push commits unless the user requests it.
- Do not commit `.build`, `bin`, `dist`, generated archives, credentials, or system override backups.
- If `.codegraph/` exists, use CodeGraph before text searches to understand code. Do not create an index automatically.
