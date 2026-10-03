# 0005. Put each voice tool behind one protocol

- Topic: Voice tool integration
- Status: Accepted
- Date: 2026-10-01
- Evidence: 74a1103, eef656b

## Context

Some tools are input methods (switch to them). Others are apps with a global hotkey (Handy).

## Decision

`VoiceProvider` hides the difference: `switchesInputSource`, `detected()`, `processIDs()`, `windowState()`. Adding a tool is one line in `builtInProviders`.

## Consequences

- Engine and the menu do not test for a tool by name.
- An app tool has no watched window, so its result shows as "not watched" in `hijack stats`.
