# 0014. Generate the diagrams from the code and from measurements

- Topic: Observability and docs
- Status: Accepted
- Date: 2026-10-03
- Evidence: 2217df4, 2ee5fa9, eb6d207, bfbb962

## Context

Hand-drawn diagrams drift from the code, and no one can check them.

## Decision

`scripts/diagrams.sh` makes the class diagram (SwiftPlantUML, with has-a edges from its own output) and the state diagram (from the state machine, by a test). `scripts/sequence.sh` makes the sequence diagram from the log or from a recording. Only `docs/diagrams/architecture.mmd` is hand-maintained, and the script warns when the code changed after it.

## Consequences

- The same commit gives the same diagrams.
- If the state diagram is old, `swift test` fails.
- Stored properties spell out their types, and enum cases go one per line, because the tool needs it.
