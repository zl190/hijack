# 0009. Reopen the app after an installer replaces it

- Topic: Distribution and signing
- Status: Accepted
- Date: 2026-10-01
- Evidence: 866db72

## Context

`brew upgrade` quits Hijack and does not start it again. The cask cannot start it: Homebrew runs install steps in a sandbox that denies `lsopen` and `appleevent-send`.

## Decision

The app registers a LaunchAgent with `SMAppService.agent`. The agent watches `/Applications/Hijack.app/Contents/MacOS/Hijack`. When the binary changes and Hijack is not running, it opens Hijack. A watch on `/Applications` itself does not fire, so the agent watches the file.

## Consequences

- Brew, curl and source installs reopen the app in about 1 s.
- When the user quits Hijack, the binary does not change, so the agent does nothing.
- macOS shows the agent once as a background item.
