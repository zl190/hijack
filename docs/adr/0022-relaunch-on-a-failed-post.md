# 0022. Relaunch on a failed post

- Topic: Faults and reliability
- Status: Accepted
- Date: 2026-10-07
- Evidence: the `nap:` field on each dictation line (W9) records whether App Nap was engaged when the post failed; docs/incidents/2026-10-04-echo-missing.md, docs/sleep-wake-event-tap-prior-art.md section 4.3, `~/Library/Logs/Hijack.log` 2026-10-04 and 2026-10-06

## Context

A long-lived Hijack process stops getting its posted talk key (Fn) into the HID stream. The dictation line
says `echo missing`. A fresh process of the same build posts fine: restart at 18:36 on 2026-10-06, then
`echo after 237ms` at 18:38. W7 rebuilds the event source before every dictation. Nobody knows yet whether that
helps, and the root cause is unknown. The only verified remedy is a fresh process.

ADR 0012 said: do not restart the app to recover, because a restart destroys the state that shows the cause.
That held while nothing measured the failure. Since W7, the summary line records both measures of a failed post
(`echo missing`, `post: not seen`), so the evidence is on disk before the restart.

## Decision

Option A, a liveness probe plus a restart policy. The industry name is the same: a liveness probe that fails,
then a restart under a back-off rule. OpenLogi (watchdog with launchd) and Karabiner (launchd daemons) do this.

**Signature**, evaluated once per dictation, right after `summary(end:)` writes its line:

- hold style, held at least 0.5 s,
- the talk key was sent (`keySentMs` is set),
- `echoMs` is nil: our tap never saw the key come back,
- `postSeen != true`: the system key state did not show it either. An unsampled probe (nil) counts as not seen,
  so a missing sample cannot block the restart.

Echo seen with the mic off does not qualify. That is the voice tool's side, and a new process would not change it.

**K = 1.** One qualifying dictation is enough. A false restart costs about one second and is rate-limited. K = 2
costs a second lost dictation in every episode, and the episodes come back to back (2026-10-06 17:13:46 and 17:13:54).

**Policy.** At most one self-relaunch per 10 minutes. The time of the last one is persisted
(UserDefaults `selfRelaunchAt`), so a process that is broken from birth cannot loop. When the limit blocks a
relaunch, the log says `self-relaunch suppressed: last one <N>m ago (...)` and nothing else happens. The check
runs after the summary, and it is skipped while a session is active (a newer press that interrupted the summary).

**Action.** Log `self-relaunch: talk key did not go out (echo missing, post not seen)`. Then relaunch through
`relaunchProcess(selfInitiated:)` in `Sources/App/System.swift`, the same function the menu's Reopen action
uses (`sleep 0.5; open -b com.zl190.hijack`, then terminate; the instance lock is released by the kernel on exit).
A UserDefaults mark is set before the terminate. The next `started:` line reads
`... (after self-relaunch)` and clears the mark, so the log shows cause, then effect.

**Seam.** `Supervisor` in `Sources/Core/Seams.swift`: `relaunch(reason:)`, `lastRelaunchAt`, `takeSelfRelaunchMark()`.
Engine owns the signature and the rate limit. The app side owns the Process call and UserDefaults.
`hijack stats` adds `self-relaunches N` to the Incidents line (the suppressed lines are not counted).

## Why not on wake, and not on a timer

Failures fell 10 minutes to 1 hour after the display came on, with successes in the same window: 2026-10-04
14:37 ok, 15:42 missing; 2026-10-06 17:13:36 ok, 17:13:46 missing. A wake or a timer trigger would restart
a healthy process and miss the broken one. Only a measured failure points at the broken process.

## Consequences

- The dictation that triggers the relaunch is lost. The next one works.
- The root cause is still unknown. The restart hides the fault from the user, not from the log: the summary line, the
  `self-relaunch:` line and the `started: ... (after self-relaunch)` line stay. `hijack stats` counts them.
- If W7's source rebuild turns out to fix the fault, the count stays at zero, and this ADR costs nothing.
- ADR 0012 is superseded for this one signature only. A restart for any other fault is still not allowed.

## Verification

`scripts/mutate-w8.sh` breaks one line of shipped code at a time. The named tests must go RED, then GREEN once
the line is restored. Output of the run on 2026-10-07:

```
PASS a relaunch call dropped: broken -> tests RED
PASS a relaunch call dropped: restored -> tests GREEN
PASS b hold threshold 0.5 s -> 0.0 s: broken -> tests RED
PASS b hold threshold 0.5 s -> 0.0 s: restored -> tests GREEN
PASS b2 hold threshold 0.5 s -> 0.6 s: broken -> tests RED
PASS b2 hold threshold 0.5 s -> 0.6 s: restored -> tests GREEN
PASS c postSeen == false instead of != true: broken -> tests RED
PASS c postSeen == false instead of != true: restored -> tests GREEN
PASS c2 postSeen condition dropped: broken -> tests RED
PASS c2 postSeen condition dropped: restored -> tests GREEN
PASS d rate limit 10 min -> 0: broken -> tests RED
PASS d rate limit 10 min -> 0: restored -> tests GREEN
PASS d2 rate limit 10 min -> 20 min: broken -> tests RED
PASS d2 rate limit 10 min -> 20 min: restored -> tests GREEN
PASS d3 relaunch time not persisted: broken -> tests RED
PASS d3 relaunch time not persisted: restored -> tests GREEN
PASS g echo condition dropped: broken -> tests RED
PASS g echo condition dropped: restored -> tests GREEN
PASS h key-sent condition dropped: broken -> tests RED
PASS h key-sent condition dropped: restored -> tests GREEN
PASS i hold-style condition dropped: broken -> tests RED
PASS i hold-style condition dropped: restored -> tests GREEN
PASS j active-session guard dropped: broken -> tests RED
PASS j active-session guard dropped: restored -> tests GREEN
PASS k started line never says after self-relaunch: broken -> tests RED
PASS k started line never says after self-relaunch: restored -> tests GREEN
PASS e stats counts suppressed lines too: broken -> tests RED
PASS e stats counts suppressed lines too: restored -> tests GREEN
PASS static grep: Menu.swift and LiveSupervisor share relaunchProcess, one open -b spawn in Sources
ALL PASS
```

Left for the owner: after install, provoke nothing. Wait for the next real `echo missing`. The log should show
the summary line, then `self-relaunch: ...`, then `started: ... (after self-relaunch)`, then a good dictation.
