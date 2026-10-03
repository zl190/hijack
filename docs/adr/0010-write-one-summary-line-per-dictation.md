# 0010. Write one summary line per dictation

- Status: Accepted
- Date: 2026-10-03
- Evidence: 6aa8349, 8b51586, 3bde067

## Context

A fault came and went. Step logs made the file long, and no step showed which part failed.

## Decision

The file log gets one line per dictation, with three checks: echo (the talk key came back through the tap), mic (the voice tool and the device), and the window. Step detail goes to the system log at debug level (`hijack log --live`). The file rotates at 1 MB. `hijack stats` reads the lines.

## Consequences

- Every fault is on record when it happens.
- The success rate and the latency percentiles come from the log, not from memory.
- Lines from before 1.1.2 have another format and are not counted.
