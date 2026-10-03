# 0013. Decide each key press in one pure state machine

- Status: Accepted
- Date: 2026-10-03
- Evidence: eb6d207, docs/state-machine.md

## Context

Four flags (`active`, `passthrough`, `forwarded`, `restoring`) held the session state in Engine. The rules for hold, tap, hands-free and "any key stops" were spread over several functions.

## Decision

`Sources/Core/SessionMachine.swift` is a pure function of state, event and mode. It returns the next state and a list of effects. Engine turns key edges into events and does the effects. Each acceptance line in `docs/state-machine.md` has a test.

## Consequences

- 12 tests cover the table. Four deliberate mutations all failed the tests.
- In hands-free mode, the key that stops the session is swallowed with its release.
- Engine's own code paths still need fault tests (see 0019).
