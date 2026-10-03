# 0002. Borrow the voice tool, do not recognize speech

- Status: Accepted
- Date: 2026-10-01
- Evidence: c6c10c5, 2632947

## Context

The owner wants the speech recognition of WeType from any input source. WeType listens only when it is the active input source and its talk key is down.

## Decision

On a press, select the voice IME (`TISSelectInputSource`), send its talk key, and switch back after the text arrives. Hijack does no speech recognition.

## Consequences

- Recognition quality is the voice tool's.
- The cost is one input-source switch (median 118 ms) and the wait for the text.
- Hijack depends on a synthetic key. Apple states that a posted Fn is not the same as the physical key (see `docs/sleep-wake-event-tap-prior-art.md`).
