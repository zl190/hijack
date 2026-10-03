# 0019. Fix the high-risk failure modes for 1.1.4

- Status: Proposed
- Date: 2026-10-03
- Evidence: a329863, 4c701e0, docs/fmea.md

## Context

The FMEA lists 26 failure modes of Engine against macOS. Engine has no fault tests, because it calls the system directly.

## Decision

Do the six FMEA actions: release a stuck modifier at start, check the tap re-enable, stop the session on wake and unlock, reset the restore source per dictation, do not send the talk key to the wrong source, watch the config folder before it exists. Put the system calls behind protocols, so that tests can inject faults.

## Consequences

- Each action names the test that verifies it (FI-1 to FI-4).
- The O scores rest on 20 dictations. Score them again after seven days of `hijack stats`.
