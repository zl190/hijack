# 0021. No hardened runtime with a self-signed identity

- Topic: Distribution and signing
- Status: Accepted
- Date: 2026-10-04
- Evidence: docs/engineering-wave-spec.md W6, docs/review-5/senior-audit.md item 5, the live test below

## Context

The senior audit asked for the hardened runtime (`codesign --options runtime`). A process with the
hardened runtime refuses injected libraries and `DYLD_*` variables. Hijack holds Accessibility and a
key tap, so injection is the threat that matters.

Hijack embeds `Sparkle.framework`. The hardened runtime turns on library validation: a loaded library
must be an Apple binary, or it must carry the same Team ID as the process.

## Live test, 2026-10-04

`build.sh` signed the framework and the app with `--options runtime` and the "Hijack Signing" identity.
`codesign` showed `flags=0x10000(runtime)` on both. `codesign --verify --deep --strict` passed.
The app did not start:

```
dyld: Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
Reason: code signature ... not valid for use in process:
mapping process and mapped file (non-platform) have different Team IDs
```

A self-signed certificate has no Team ID (`TeamIdentifier=not set`). Library validation compares Team IDs,
not certificates. Two binaries with the same self-signed certificate still fail the check.

## Decision

Do not sign with the hardened runtime while the identity is self-signed.

The two ways out, and why neither is taken now:

1. The entitlement `com.apple.security.cs.disable-library-validation`. It turns the check off, so the
   runtime no longer protects against the main threat. The flag would then exist for appearance only.
2. A Developer ID certificate. It carries a Team ID, so library validation accepts the re-signed framework.
   This costs an Apple Developer account. It also changes the designated requirement, so every user grants
   Accessibility again once. Revisit when the user count makes the account worth it.

## Consequences

- `build.sh` signs without `--options runtime`. The threat model lists library injection as a residual risk.
- The install path stays: self-signed, not notarized, quarantine removed by the cask or the installer.
- The audit item 5 is closed as "decided, not done".
