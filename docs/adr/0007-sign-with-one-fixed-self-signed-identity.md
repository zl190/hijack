# 0007. Sign with one fixed self-signed identity

- Status: Accepted
- Date: 2026-10-01
- Evidence: 03b1eb4

## Context

macOS keys the Accessibility grant to the code signature. An ad-hoc signature changes on each build, so the user must grant again. The project has no Apple Developer account.

## Decision

Sign every build with the identity "Hijack Signing". Ship by curl and by a Homebrew cask. The cask removes the quarantine flag in `postflight_steps`.

## Consequences

- The grant survives updates.
- The app is not notarized. It has no Team ID (see 0008).
- `codesign` asks for keychain access until the user selects "Always Allow".
