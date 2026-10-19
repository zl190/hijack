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
| `following` | Follow mode (ADR 0024): the tool's own talk key is held and the tool is switching itself in; the key passes, nothing is posted, the previous input source is remembered |
| `waitingForText` (follow) | Also reached without any key: the tool switched itself in (`toolStarted`), and its window or microphone says when it is done |
| `starting` | Shortcut pressed, waiting for the input source switch (and the hold delay) before sending the talk key |
| `listening` | Talk key sent, the voice tool is listening |
| `waitingForText` | Talk key released, waiting for the voice window to go before switching back (input methods only) |

## Events

`press`, `release` — edges of the physical shortcut (repeats and releases whose press we never saw are filtered
before the machine). `otherKey` — another key while a toggle session runs and "any key stops" is on.
`keySent` — the switch is ready, send the talk key. `textDone` — the voice window went (or the wait timed out).
`switchFailed` — the input source did not switch within `maxSwitchWait`: the talk key stays unsent (FM-05).
`quit` — the app is quitting: stop now and release the talk key if it was sent, skipping `waitingForText` (FM-10).
`toolStarted` — follow mode (ADR 0024): the system's selected input source changed into the voice source and Hijack did
not select it: the tool started itself. The one signal left when the tool's own key listener swallows the physical
talk key before our tap sees it (field, 2026-10-19 19:50).

Modes (fixed per press): `toggle`, `switchesInput`, `passthrough` (the tool is already active, so its own key goes to
it), `follow` (ADR 0024: the tool starts itself on its own talk key; Hijack only switches back). Toggle wins over
both; passthrough wins over follow.

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
13. When the shortcut is pressed in `idle` (or in `waitingForText`, after finishing the previous dictation) in follow mode and passthrough does not apply, the machine shall go to `following`, pass the key, begin a dictation and remember the current input source; it shall neither switch the input source nor schedule or send the talk key. A repeat press in `following` shall pass. `keySent`, `textDone`, `switchFailed` and `quit` in `following` shall change nothing.
14. When the shortcut is released in `following`, it shall pass the key and, for an input method, go to `waitingForText`; for an app, go to `idle` and finish. Nothing is released: nothing was sent.
15. In follow mode, when the voice source is already active at the press and there is no source to go back to (none pending from the previous dictation, none tracked), the press shall pass through as in 1 (the engine decides this per press; a press while the previous text is still awaited chains as 13 and keeps the remembered source; a press inside the voice source with a tracked source goes to `following` as 13 and restores to it).
16. When `toolStarted` arrives in `idle` in follow mode for an input method, the machine shall go to `waitingForText`, begin a dictation, remember the source and watch the tool (`watchTool`: its voice window, else its microphone, then `textDone`); in `waitingForText` it shall first finish the previous dictation, then do the same; in `following` (the key is held: its release watches) and in every other state, and outside follow mode or for an app, `toolStarted` shall change nothing. The release in `following` shall watch the tool (`watchTool`) rather than the window alone.
