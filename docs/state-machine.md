# Dictation state machine

`Sources/Core/SessionMachine.swift` is the single place that decides what a key press does. It is pure (no AppKit,
no timers): it takes an event and the mode, moves to the next state and returns effects. `Engine` turns key
events into these events and carries the effects out (switch input source, post the talk key, poll for the
text, write the summary). `docs/diagrams/states.mmd` is generated from the same table by the tests.

## States

| State | Meaning |
|---|---|
| `idle` | Nothing running |
| `passthrough` | The shortcut is the voice tool's own key and the tool is already active: the key goes to it untouched |
| `starting` | Shortcut pressed, waiting for the input source switch (and the hold delay) before sending the talk key |
| `listening` | Talk key sent, the voice tool is listening |
| `waitingForText` | Talk key released, waiting for the voice window to go before switching back (input methods only) |

## Events

`press`, `release` — edges of the physical shortcut (repeats and releases whose press we never saw are filtered
before the machine). `otherKey` — another key while a toggle session runs and "any key stops" is on.
`keySent` — the switch is ready, send the talk key. `textDone` — the voice window went (or the wait timed out).
`switchFailed` — the input source did not switch within `maxSwitchWait`: the talk key stays unsent (FM-05).
`quit` — the app is quitting: stop now and release the talk key if it was sent, skipping `waitingForText` (FM-10).

## Acceptance (EARS)

1. When the shortcut is pressed in `idle` and passthrough applies, the machine shall go to `passthrough` and pass the key.
2. When the shortcut is pressed in `idle` otherwise, it shall go to `starting`, swallow the key, begin a dictation, and schedule the talk key; for an input method it shall also switch to it.
3. When `keySent` arrives in `starting`, it shall go to `listening` and send the talk key; in any other state `keySent` shall change nothing.
4. While in hold mode, when the shortcut is released in `starting` or `listening`, it shall swallow the key and, for an input method, go to `waitingForText`; for an app, go to `idle` and finish. It shall release the talk key only if it was sent (`listening`).
5. While in toggle mode, releasing the shortcut in `starting` or `listening` shall only swallow the key; pressing it again shall stop as in 4.
6. While in toggle mode, `otherKey` in `starting` or `listening` shall stop as in 4 and swallow that key and its release.
7. When `textDone` arrives in `waitingForText`, it shall go to `idle` and finish; elsewhere `textDone` shall change nothing.
8. When the shortcut is pressed in `waitingForText`, it shall first finish the previous dictation, then act as a press in `idle`.
9. When the shortcut is released in `passthrough`, it shall go to `idle` and pass the key.
10. Every state shall have an outcome for every event (no undefined transitions).
11. When `switchFailed` arrives in `starting`, it shall go to `idle` and finish without sending the talk key; elsewhere `switchFailed` shall change nothing.
12. When `quit` arrives in `starting` or `listening`, it shall go to `idle` and release the talk key only if it was sent (`listening`), without waiting for text; elsewhere `quit` shall change nothing.
