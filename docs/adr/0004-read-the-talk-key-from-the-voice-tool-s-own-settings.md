# 0004. Read the talk key from the voice tool's own settings

- Status: Accepted
- Date: 2026-10-01
- Evidence: 3da1071, fb69ecf

## Context

Each voice tool has its own talk key. A wrong key starts nothing.

## Decision

Read the key from the tool's settings, read-only: WeType from its MMKV file (the last value inside the live length only), Handy from `settings_store.json`. A key that the user sets in `config.json` wins over the detected key.

## Consequences

- Hijack follows a key change in the voice tool (see 0016 for the file watch).
- The MMKV format is private. If WeType changes it, detection fails and the user must set the key.
