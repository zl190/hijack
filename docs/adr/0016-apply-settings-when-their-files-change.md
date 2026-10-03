# 0016. Apply settings when their files change

- Topic: Settings
- Status: Accepted
- Date: 2026-10-03
- Evidence: d322e5e, 65897a1

## Context

A 1 s timer read the config and the voice tool's settings, also when idle.

## Decision

Watch the config folder and the voice tools' settings files with FSEvents (file events, `NoDefer`). Refresh the settings snapshot after a dictation ends, not during it.

## Consequences

- Idle CPU went from 130 ms to 10 ms per minute.
- With `NoDefer` the app reads a change in 11 to 13 ms. The reason for short delays without `NoDefer` is not known.
- If the config folder does not exist at launch, the watch misses it (FMEA action 6).
