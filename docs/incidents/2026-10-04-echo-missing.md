# Incident 2026-10-04: the talk key did not go out (echo missing)

Status: fix in progress (W7). Source: `~/Library/Logs/Hijack.log`, build 1.1.4 (signed, installed 2026-10-03 23:27).

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

## Experiment (ticket W7, implemented 2026-10-06)

1. (Implemented: `LiveKeyPoster` in `Sources/App/System.swift`, `Engine.post`, `reconcileAfterWake`.) Hold one explicit `CGEventSource(stateID: .hidSystemState)` in `LiveKeyPoster` and post through it.
   Rebuild it on `didWake` and on the first post after a gap longer than 10 minutes. Log `event source
   rebuilt (reason)`.
2. (Implemented: `Engine.sampleWhileHeld`, `Engine.summary`.) 0.3 s after the talk key goes out, read `flagsState` (modifier-only key) or `keyState` (other key) through the tap and put
   the result on the summary line as `post: seen` / `post: not seen` / `post: ?` (`?`: released before the sample, or a tap-style key that is already up). This separates "post failed" from "tool ignored".
3. (Kept.) Keep the echo probe. With 1 and 2, the next occurrence tells which hypothesis holds.

Acceptance: a dictation after a system sleep shows `echo after N ms` and `post: seen`; the summary line
of a failed post shows `post: not seen` and the next dictation shows `event source rebuilt`.

## 2026-10-06 recurrence

- The process started 2026-10-04 18:19 and went through 6 system sleeps by 2026-10-06.
- 2026-10-06, 10 dictations: 8 `echo missing`, 1 `mic off`, 1 ok. Success rate 33%.
- `hijack doctor` was all green during the failures (Accessibility granted, tap active). Not a permission or tap fault.
- Restart experiment: Hijack quit and relaunched at 18:36:29 with the same 1.1.4 build. The next dictation at 18:38:20
  logged `echo after 237ms, mic tool on device on, window while held: 1 window`, and the text came back after 3.85 s.
  A fresh process posts fine; the old one could not. This matches H3 of `docs/review-3/senior-review.md`.
- Residual: 17:13:36 the same day (and row 3 above) saw the echo with the mic still off. H3 does not explain it. The
  `post:` field separates the two: `post: seen` with `mic tool off` points at the tool, `post: not seen` at the source.

### What W7 changed

- `LiveKeyPoster` holds one `CGEventSource(stateID: .hidSystemState)`; every event goes through it. `rebuild(reason:)`
  swaps it and logs `event source rebuilt (<reason>)`.
- `Engine` rebuilds on `reconcileAfterWake(.systemWake)` (reason `system wake`; a screen unlock does not) and before the
  first post after more than 10 minutes without a post (reason `idle <N>m`).
- The summary line carries `post: seen` / `post: not seen` / `post: ?` after the echo field. Stats reads it; a line with
  `post: not seen` and no echo field counts under `talk key never went out`.
- Mutation checks: `scripts/mutate-w7.sh` (output below). Tests: `Tests/HijackCoreTests/EventSourceTests.swift`, `StatsTests`.

### Mutation check output (`scripts/mutate-w7.sh`, 2026-10-06)

```
PASS a rebuild-on-wake dropped: broken -> tests RED
PASS a rebuild-on-wake dropped: restored -> tests GREEN
PASS a2 rebuild also on screen unlock: broken -> tests RED
PASS a2 rebuild also on screen unlock: restored -> tests GREEN
PASS b idle threshold 10 min -> 100 min: broken -> tests RED
PASS b idle threshold 10 min -> 100 min: restored -> tests GREEN
PASS b2 idle boundary > -> >=: broken -> tests RED
PASS b2 idle boundary > -> >=: restored -> tests GREEN
PASS c summary always prints post: seen: broken -> tests RED
PASS c summary always prints post: seen: restored -> tests GREEN
PASS d stats ignores post: not seen: broken -> tests RED
PASS d stats ignores post: not seen: restored -> tests GREEN
ALL PASS
```

Left for the owner: a dictation after a real system sleep shows `echo after N ms` and `post: seen`; a failed post shows
`post: not seen` and the next dictation shows `event source rebuilt`.
