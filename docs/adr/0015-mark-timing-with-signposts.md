# 0015. Mark timing with signposts

- Topic: Observability and docs
- Status: Accepted
- Date: 2026-10-03
- Evidence: 7570709, bf6852b

## Context

We needed to see where time goes in a dictation.

## Decision

Use `OSSignposter` in Points of Interest: one interval per dictation, its phases, and its events. Use Instruments (`xctrace`) to profile. Make the everyday sequence diagram from the log, because macOS keeps signposts only while a recording runs.

## Consequences

- Signposts cost nothing when no one records.
- A recording takes signposts only about 6 s after it starts.
