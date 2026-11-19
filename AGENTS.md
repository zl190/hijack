# hijack-paved-road — agent contract

Read `README.md` first (product, install, release flow). This file holds what the codebase cannot say for itself: the rules agents keep
getting wrong and who enforces each one. Keep it under 200 lines; `CLAUDE.md` is a one-line `@AGENTS.md` shim.

## Checks

`scripts/check.sh [--fast]` runs every declared check (`checks.json`); CI runs the same command. A change is
green when that one command exits 0. Clear a violation the checks find; never explain it in a comment.

## Rules

One row per rule. The enforcer column names what fails when the rule is broken: `hook:<name>`, `check:<name>`,
`lint:<name>`, `test:<name>`, or `none`. A `none` row whose mistake recurs is the input to `/pstack:correct`.

| Rule | Enforced by | Source |
|---|---|---|
| Every check this repo relies on is declared in `checks.json` | check:scripts/check.sh | paved-road init |
| Swift files match `.swift-format` (blocking since 2026-10-04) | check:lint (`make lint`) | docs/swift-format.md |
| HijackCore unit tests pass; Sparkle is fetched first | check:test (`make test`) | Makefile |
| The app builds ad-hoc; an install uses `make install SIGN_ID="Hijack Signing"` or Accessibility permission is lost | check:build (`make build`); install step none | memory project_hijack |
