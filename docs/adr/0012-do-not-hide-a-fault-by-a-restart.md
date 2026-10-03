# 0012. Do not hide a fault by a restart

- Status: Accepted
- Date: 2026-10-03
- Evidence: docs/sleep-wake-event-tap-prior-art.md

## Context

A long-running process stopped working, and a new process worked. A watchdog restart and a tap rebuild on wake were proposed.

## Decision

Do not restart the app to recover. Do not rebuild the tap on wake without evidence. First record the fault (0010), then fix the cause.

## Consequences

- A restart destroys the state that shows the cause.
- In the failed process the tap still saw the shortcut, so a tap rebuild had no evidence.
- FMEA action 3 stops an active session on wake and unlock. That is a session rule, not a tap rebuild.
