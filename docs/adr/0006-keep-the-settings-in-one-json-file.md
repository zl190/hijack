# 0006. Keep the settings in one JSON file

- Topic: Settings
- Status: Accepted
- Date: 2026-10-01
- Evidence: b5c3b10, 3c5911b

## Context

The menu, the settings window, the CLI and the user's own edits all change settings.

## Decision

`~/.config/hijack/config.json` is the single source of truth. All surfaces edit this file. If the file does not parse, keep the last values and do not overwrite the file.

## Consequences

- A hand edit is never lost by a menu click.
- An agent can change settings with `hijack set`.
