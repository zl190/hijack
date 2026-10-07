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
   Rebuild it before every dictation's press and on `didWake` (changed after review: the field log shows staleness flapping within a degraded run, 17:13:36 echo then 17:13:46 missing with no sleep between, so a wake or idle trigger alone cannot pass the acceptance below). Log `event source
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
- `Engine` rebuilds before every dictation's talk-key press (`sendKey`, reason `dictation`) and on
  `reconcileAfterWake(.systemWake)` (reason `system wake`, a log marker; a screen unlock does not). A failed rebuild keeps the old source and logs it.
- The probe reads the key state in both `.hidSystemState` and `.combinedSessionState`; `post: seen` means either showed it.
  The trace line `post sample hid=<on/off> session=<on/off>` (`hijack log --live`) tells which state works.
- The summary line carries `post: seen` / `post: not seen` / `post: ?` after the echo field. Stats reads it; a line with
  `post: not seen` and no echo field counts under `talk key never went out`.
- Mutation checks: `scripts/mutate-w7.sh` (output below). Tests: `Tests/HijackCoreTests/EventSourceTests.swift`, `StatsTests`.

### Mutation check output (`scripts/mutate-w7.sh`, 2026-10-06)

```
PASS a rebuild-on-wake dropped: broken -> tests RED
PASS a rebuild-on-wake dropped: restored -> tests GREEN
PASS a2 rebuild also on screen unlock: broken -> tests RED
PASS a2 rebuild also on screen unlock: restored -> tests GREEN
PASS b per-dictation rebuild dropped: broken -> tests RED
PASS b per-dictation rebuild dropped: restored -> tests GREEN
PASS b2 rebuild moved after the press post: broken -> tests RED
PASS b2 rebuild moved after the press post: restored -> tests GREEN
PASS c summary always prints post: seen: broken -> tests RED
PASS c summary always prints post: seen: restored -> tests GREEN
PASS c2 post sample reads hid only: broken -> tests RED
PASS c2 post sample reads hid only: restored -> tests GREEN
PASS d stats ignores post: not seen: broken -> tests RED
PASS d stats ignores post: not seen: restored -> tests GREEN
PASS static grep: Sources/App/System.swift creates events through the explicit source
ALL PASS
```

Left for the owner: a dictation after a real system sleep shows `echo after N ms` and `post: seen`; a failed post shows
`post: not seen` and the next dictation shows `event source rebuilt`.

## W8 (2026-10-07): self-relaunch on a failed post

Owner decision: a liveness probe and a restart policy, not a restart on wake or on a timer. After a hold-style
dictation (held 0.5 s or more, talk key sent) with `echo missing` and `post` not seen (nil counts as not seen), the app
logs `self-relaunch: ...` and starts a fresh process, at most once per 10 minutes. The next `started:` line ends with
`(after self-relaunch)`. The dictation that triggers it is lost. The root cause is still open. See
`docs/adr/0022-relaunch-on-a-failed-post.md`.

Review round 1 of W8 (2026-10-07) found three gaps on the relaunch path and one smaller one; all are fixed:

1. The old process could still be alive when the relauncher opened the app (a fixed `sleep 0.5`). Now the shell waits for our
   pid (cap 10 s, then `open -b` anyway), and `main.swift` retries the instance lock for up to 3 s after a self-relaunch. A failed
   spawn no longer quits the app and no longer uses up the rate limit (`Supervisor.relaunch` returns Bool).
2. For an app provider the summary, and so the relaunch, ran inside the CGEventTap callback. The relaunch now runs on the next
   main-loop turn, with the active-session check repeated there.
3. The log is written on a background queue and `terminate` ends in `exit()`, so the evidence lines could be lost. The queue is
   flushed before the quit and in `applicationWillTerminate`.
4. The self-relaunch mark could outlive a process that died before `start()`. It is now read and cleared in `main.swift` right
   after the CLI dispatch.

## W9 (2026-10-07): App Nap state on every dictation line

Owner observation, 2026-10-07: while the fault is on, switching to WeType by hand and holding the physical Fn works. So the
break is only in Hijack's posted Fn. Owner's hypothesis: the system degraded the process (swap, App Nap). Hijack is an
`LSUIElement` accessory with no `beginActivity` declaration, so it is eligible for App Nap. Whether it was napped at failure
time is unknown.

W9 makes it visible. A process can read its own App Nap state without root: `task_policy_get` with flavor
`TASK_SUPPRESSION_POLICY` (3) returns 16 `integer_t` words (XNU `osfmk/mach/task_policy_private.h`, not in the SDK, so
declared by hand); word 0 is `active` (1: App Nap engaged). Flavor 1 (`TASK_CATEGORY_POLICY`) gives the task role.
`TASK_POLICY_STATE` (4) is root-only and is not used. On this machine (macOS 26) the call returns `KERN_SUCCESS`, count 16,
all zero on a non-napped process.

- Summary line: `post: ..., nap: on|off|?, role: N, mic tool ...` (sampled with the post probe, 0.3 s after the talk key; `?` when not sampled or unreadable, and then no role).
- `started:` and `self-relaunch:` lines end with ` nap=on|off|?`, read at that moment: the state of the process about to die and of the new one.
- `hijack stats`: `App Nap  napped during N of M sampled dictations (K of those failed)`; `--json`: `nappedSampled`, `napped`, `nappedFailed`.

Caveat: `active=1` has not been observed on this machine yet (a nap cannot be forced on demand). The mapping "App Nap =
suppression `active`" is the documented implementation of App Nap, not something measured here.

The role read can fail while the nap read works: then the line has `nap: on|off` and no `role:`. `active` is `raw[0] != 0`.

Mutation checks (`scripts/mutate-w9.sh`, 2026-10-07):

```
PASS a summary always prints nap: off: broken -> tests RED
PASS a summary always prints nap: off: restored -> tests GREEN
PASS a2 unreadable prints nap: off: broken -> tests RED
PASS a2 unreadable prints nap: off: restored -> tests GREEN
PASS b stats counts nap: ? as napped: broken -> tests RED
PASS b stats counts nap: ? as napped: restored -> tests GREEN
PASS b2 stats counts nap: ? as sampled: broken -> tests RED
PASS b2 stats counts nap: ? as sampled: restored -> tests GREEN
PASS c sample taken from postSeen instead of the probe: broken -> tests RED
PASS c sample taken from postSeen instead of the probe: restored -> tests GREEN
PASS d started line drops the nap suffix: broken -> tests RED
PASS d started line drops the nap suffix: restored -> tests GREEN
PASS d2 relaunch line drops the nap suffix: broken -> tests RED
PASS d2 relaunch line drops the nap suffix: restored -> tests GREEN
PASS e sample moved to every state (no hold-style gate): broken -> tests RED
PASS e sample moved to every state (no hold-style gate): restored -> tests GREEN
PASS static grep: LiveProbes uses flavor 3 with count 16 and never flavor 4
ALL PASS
```
