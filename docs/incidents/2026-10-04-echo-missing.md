# Incident 2026-10-04: the talk key did not go out (echo missing)

Status: open. Source: `~/Library/Logs/Hijack.log`, build 1.1.4 (signed, installed 2026-10-03 23:27).

## What the log shows

Three dictations in a row at 15:42 to 15:43, front app Claude for desktop, voice tool WeType, hold mode:

| Time | Held | Fn sent after | Echo | Mic (tool / device) | WeType window | Outcome |
|---|---|---|---|---|---|---|
| 15:42:44 | 2.73 s | 266 ms | missing | off / off | none | no window, back after 2.54 s |
| 15:42:53 | 2.03 s | 241 ms | missing | off / off | none | window closed 2108 ms after release |
| 15:43:09 | 2.14 s | 231 ms | after 235 ms | off / off | none | no window, back after 2.51 s |

One `slow key event (another key): 108 ms old on arrival` sits between the first two. No `event tap was
disabled` line and no `catching up` line in that period.

Process history before the incident: started 23:27 the day before; screen sleeps at 00:25 and 12:23;
one system sleep at 12:41 with wake at 13:09; screen sleeps at 14:04 and 14:14. The process had run for
16 hours and had been through one system sleep.

## Reading

- Rows 1 and 2: Hijack posted Fn, and its own tap never saw the press come back. The post did not reach the
  HID event stream. WeType did not listen. This matches hypothesis H3 of `docs/review-3/senior-review.md`:
  the implicit event source (`CGEvent(keyboardEventSource: nil, ...)`) goes stale in a long-lived process,
  with sleep as the likely trigger.
- Row 3: the press came back, so the post reached the stream, and WeType still did not listen. One of:
  WeType's own state after rows 1 and 2; a stuck modifier (H2); or the tool needs more than one press
  after a stale period. The echo alone does not settle it.
- The success rate for the day is 88.5% because of these rows. The SLO line prints `not met`.

## Experiment (ticket W7, not started)

1. Hold one explicit `CGEventSource(stateID: .hidSystemState)` in `LiveKeyPoster` and post through it.
   Rebuild it on `didWake` and on the first post after a gap longer than 10 minutes. Log `event source
   rebuilt (reason)`.
2. After each post, read `CGEventSource.flagsState(.hidSystemState)` and `keyState` for the talk key and put
   both on the summary line as `post: seen/not seen`. This separates "post failed" from "tool ignored".
3. Keep the echo probe. With 1 and 2, the next occurrence tells which hypothesis holds.

Acceptance: a dictation after a system sleep shows `echo after N ms` and `post: seen`; the summary line
of a failed post shows `post: not seen` and the next dictation shows `event source rebuilt`.
