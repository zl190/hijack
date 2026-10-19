# Incident 2026-10-04: the talk key did not go out (echo missing)

Status: cause since 2026-10-17 found on 2026-10-19 (WeType 3.0's exclusive-mode key listener; section at the end). Hijack side: W10 (docs/adr/0023) names the listener; W11 (docs/adr/0024, follow mode) stops posting the key and only switches back, since the field tests at the end show WeType 3.0 acts on a physical Fn and on nothing Hijack can post. W7 to W9 below are history. Source: `~/Library/Logs/Hijack.log`, build 1.1.4 (signed, installed 2026-10-03 23:27).

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

## 2026-10-19: since 10-17 the talk key is swallowed by WeType 3.0's key listener (W10)

Owner's question: a process restart stopped fixing the fault on 10-18. Four leads were measured; the artifacts are below.
Scripts: `scripts/taps.swift` (the event-tap chain with process names), `hijack doctor` (the same read, one line), and the
`ahead:` field on every dictation line.

### What changed on 2026-10-17

- `/Library/Input Methods/WeType.app` was replaced at 15:53:38 by WeType 3.0.0 (build 670, binary built 2026-10-15 07:09). The
  WeType process 94224 started at 15:53:35 and is the one on every failure line since (`no window (pid 94224)`, 18 lines).
- Dictations with the talk key sent, from the log: 10-12 to 10-16: 17 sent, 0 `echo missing`, 15 with the mic on (the two
  others were too short to judge). From 10-17 15:53 on: 21 sent, 20 `echo missing`, 1 good (10-19 00:10:38).
- Every self-relaunch since 10-18 (7 of the 8 ever) was followed by `echo missing` within seconds to minutes. The one
  self-relaunch before (10-11) and the manual restart of 10-06 were followed by good dictations. The restart stopped
  helping on the day WeType 3.0 arrived.

### Lead 1: the event-tap chain, and the slow key events

`scripts/taps.swift` (CGGetEventTapList, 2026-10-19 15:20, after Hijack had restarted at 15:13:46):

```
order | id        | location | filter/listen | key events | enabled | pid process
 0    | 622680824 | hid      | filter        | keys       | on      | 94224 WeType
 1    | 403916267 | hid      | filter        | keys       | on      | 13440 Hijack
12    | ...       | hid      | listen        |            | on      |   681 Karabiner-Core-Service
13    | ...       | hid      | filter        | keys       | on      |  1217 LinearMouse
```

WeType's process is two days older than Hijack's, yet its tap is listed first. Three facts settle what that means:

1. A tap created later is listed first and runs first. Measured with a scratch process (not kept in the repo) that
   created two head-inserted listen-only taps 1 ms apart and posted eight key events, five of which reached the HID
   taps; the younger tap was listed first and its callback ran first each time: `hid-head2 +89.4ms | hid-head +89.6ms`, `+65.3 | +65.5`, `+65.7 | +66.1`,
   `+65.0 | +65.7`, `+205.3 | +205.6` (ms after the post). So the list is newest-first for head-inserted taps, and
   list order is run order for them in one process; that it also holds for filtering taps across processes is
   inferred, not measured.
2. WeType re-creates its tap whenever a new tap appears. Poll of the list every 100 ms around `hijack restart`:

   ```
   15:33:02.834  #0 WeType id 2064101247   #1 Hijack(48608) id 595543064
   15:33:08.824  hijack restart issued
   15:33:09.021  #0 WeType id 2064101247                                    (old Hijack gone)
   15:33:09.973  #0 Hijack(95012) id 2001057841   #1 WeType id 2064101247   (our new tap is first)
   15:33:13.564  #0 WeType id 254912071           #1 Hijack(95012)          (WeType re-created its tap, 3.6 s later)
   ```

   WeType's tap id was 622680824 at 15:20, 452076074 at about 15:27 (after Hijack's self-relaunch at 15:24:03 created a
   new tap), 2064101247 at 15:29 (after the scratch process created its taps at about 15:27) and 254912071 at 15:33 (the
   poll above). Only the 15:33 change was watched as it happened; the other three are before-and-after readings with one
   new tap in between each. Nothing else in the list moved.
3. The WeType binary names the mechanism. `strings` on `WeType.app/Contents/MacOS/WeType`: `[ShortcutKeyMonitor] COMPETITOR
   DETECTED:`, `No flagsChanged competitors found (`, `Force recreating EventTap, reason:`, `Exclusive mode state: ...,
   healthCheck: always, competitorDetection:`, `boostExclusivePriorityIfNeeded`, `settingfunction_voiceInputExclusiveMode`,
   `voiceInputExclusiveMode setting changed!`, `[ShortcutKeyMonitor][CGEvent] Fn key `, `[ShortcutKeyMonitor][CGEvent]
   injected keyboard event bypass key=0x`, and source paths `WeType/Module/Input/ShortcutKeyMonitor.swift`,
   `ExternalKeyboardMonitor.swift`, `VoiceInput/VoiceInputDeviceLevelMonitor.swift`. WeType's own log files
   (`~/Library/Caches/WeType/Logs/wt_*.xlog`) are encrypted (xlog magic 0x07) and were not read.

So on 10-19, whenever the chain was read, WeType's filtering tap was listed before ours, and a restart of ours won the
first place for about four seconds. The list was not read before 10-19; that the same order held since the update is
inferred from the failure pattern. The post itself is fine: the Hijack-exact Fn (HID-state source, flagsChanged, key 63,
`maskSecondaryFn`, the user-data marker) posted from the same scratch process reached a head tap at +89.4 ms, a
tail-appended HID tap at +101.6 ms and an annotated-session tap at +415.8 ms while Squirrel was the active input source. In a real dictation WeType is the active source, and our tap sees nothing:
the only filtering tap between the head and ours is WeType's. What WeType does with it is its own business; its
`injected keyboard event bypass` string says it tells injected events apart, and the 00:10:38 success says it sometimes
acts on ours. That part is not measured here.

Slow key events (`Nms old on arrival`): the age is measured when our callback starts, so it is the sum of everything
before our tap. LinearMouse's tap (pid 1217, from the 10-10 boot) is listed after ours and Karabiner's is listen-only:
neither can delay our arrival, and the quit-them-one-at-a-time test is unnecessary. The one filtering tap ahead of ours
is WeType's. The upstream part is large by itself: the scratch posts above took 65 to 205 ms to reach the very first tap
on a machine at load average 36 with WindowServer at 50 % CPU (`uptime`, `ps`, 15:29). The count is not a WeType-3.0
signal on its own: 42 on 10-16, before the update, 196 on 10-18, 2 on 10-19.

### Lead 2: the `post:` probe

`post: seen` never appeared: 0 of 48 good dictations (23 carried `post: not seen`, the rest predate the field).
`CGEventSource.flagsState` in both the HID and the combined session state reflects the keyboard, not a posted
flagsChanged. The field answered nothing and is dropped (W10). Its slot carries `ahead:` now.

### Lead 3: `cleared a stuck Fn`

Two lines ever, 15:11:13.489 and 15:11:27.238 on 10-19, each 1.05 s after a `started:` line that followed a manual restart
(`hijack restart` at 15:11:11, the menu at 15:11:25). None after the starts at 15:10:58, 15:13:41, 15:13:43, 15:13:46.
The check reads `flagsState(.hidSystemState)`, which (lead 2) shows only what the keyboard reports: Fn was physically down
at those two moments and up two minutes later. A stuck key would have stayed. The simplest reading is a hand on the
physical Fn right after each restart (the owner was testing physical Fn that afternoon). Why the 1 s guard did not see
the edge is not explained: both lines fall inside the few seconds after a start when our new tap is first. Not a
software fault by the evidence; owner to confirm the hand.

### Lead 4: the Claude desktop app

No Claude process (pids 49611, 49623, 49646, 49690, 49691, 49760, 51554, 51555) owns an event tap. Secure Input is off
(`ioreg` has no `kCGSSessionSecureInputPID`; 0 `secure input on` lines in the whole log). `front=com.anthropic.claudefordesktop`
is on 17 of 17 good dictations of 10-03 and on the 10-19 00:10 success; the 10-06 failures had `front=com.mitchellh.ghostty`
and `com.openai.codex`. The correlation is usage, not cause. Killed.

### What W10 changed

- `Engine`: the first held sample reads the chain once, off the main thread (`TapControl.listenersAhead(for:)`;
  `CGGetEventTapList` measured by `scripts/taplist-latency.swift` at load average 29 to 37: `p50 1.974 ms  p95 3.914 ms
  max 12.068 ms` over 200 calls). The
  dictation line carries `ahead: none | <names joined by +> | ?` where `post:` was: the older processes whose
  filtering taps for the talk key's event type are listed before ours (a younger process ahead of us is ordinary
  creation order and is not named; a relaunch puts us back in front of it). A failed post behind such a listener logs
  `self-relaunch skipped: <names>'s key listener sits ahead of ours (...)` instead of relaunching (docs/adr/0023).
  The judge is pure (`Sources/Core/KeyListenerChain.swift`, `KeyListenerChainTests`); the app side only reads the list.
- `hijack doctor`: `✓ no other key listener sits ahead of Hijack's`, `⚠︎ WeType keeps a key listener ahead of Hijack's`
  with what to do, or `⚠︎ Hijack's key listener is not in the system's list` while the app restarts. `hijack stats`: a
  `Key listener` line, a cause bucket `talk key taken by another app's key listener`, and `aheadSampled` /
  `listenerAhead` / `listenerAheadFailed` in `--json`.
- `scripts/taps.swift`: the whole chain with names, for a reader.
- Tests: `Tests/HijackCoreTests/ListenerChainTests.swift`. Mutation checks: `scripts/mutate-w10.sh` (output below);
  `mutate-w7/w8/w9.sh` lost their `post:` entries; all four scripts were run on 2026-10-19: w7, w9 and w10 ALL PASS; w8's
  sixteen mutations PASS (after round 2 of the review, which caught a mutant that only failed to compile; every script
  now fails a mutant that does not build) and its static grep "one `open -b` spawn" FAILs on the restart-button branch because
  `hijack restart` added a second spawn (a PR #7 item, not touched here).

### Mutation check output (`scripts/mutate-w10.sh`, 2026-10-19)

```
PASS a summary always prints ahead: none: broken -> tests RED
PASS a summary always prints ahead: none: restored -> tests GREEN
PASS a2 unreadable chain prints ahead: none: broken -> tests RED
PASS a2 unreadable chain prints ahead: none: restored -> tests GREEN
PASS b chain read on every sample: broken -> tests RED
PASS b chain read on every sample: restored -> tests GREEN
PASS c relaunch guard inverted (skips when ours is first): broken -> tests RED
PASS c relaunch guard inverted (skips when ours is first): restored -> tests GREEN
PASS c2 relaunch guard dropped: broken -> tests RED
PASS c2 relaunch guard dropped: restored -> tests GREEN
PASS c3 unread chain counts as a listener ahead: broken -> tests RED
PASS c3 unread chain counts as a listener ahead: restored -> tests GREEN
PASS d stats ignores the ahead field: broken -> tests RED
PASS d stats ignores the ahead field: restored -> tests GREEN
PASS d3 stats keeps the keyNotSent cause behind a listener: broken -> tests RED
PASS d3 stats keeps the keyNotSent cause behind a listener: restored -> tests GREEN
PASS d2 stats counts a failure as any listener ahead: broken -> tests RED
PASS d2 stats counts a failure as any listener ahead: restored -> tests GREEN
PASS static grep: the live rows carry hid/enabled/filtering, one chain function, used by doctor, read inside offMain
ALL PASS
```

### Field tests after the W10 install (2026-10-19, 16:28 to 16:51)

Each test is one setting changed by the owner, then one dictation; the line is quoted from the log.

| Test | Line | Reading |
|---|---|---|
| Baseline, W10 installed | 16:28:36 `echo missing, ahead: WeType, mic tool off, no window (pid 94224)` then `self-relaunch skipped: WeType's key listener sits ahead of ours` | the field and the skip work; nothing else changed |
| WeType's「快捷键全局生效」(`voiceShortcutGlobalEnabled`) turned off | 16:28:44 same as above | not the exclusive mode; the chain did not change |
| WeType's Accessibility permission revoked (its tap left the list: 19 taps, Hijack #0, doctor green) | 16:47:05 `echo after 255ms, ahead: none, mic tool off, window while held: 1 window` | the echo is back: WeType's tap was the swallower. The one window was WeType's own panel「按住「fn」使用语音输入 — 开启辅助功能权限后…」: WeType 3.0 refuses Fn voice without Accessibility, and its「自定义快捷键」panel needs it too. Permission restored. |
| Hijack posts without its user-data tag (`ours` read from `kCGEventSourceUnixProcessID`), WeType's tap back in front | 16:51:27 `echo missing, ahead: WeType, mic tool off` | the tag is not what WeType judges by; reverted |

What is left on the table: WeType's `[ShortcutKeyMonitor][CGEvent] injected keyboard event bypass` string and the four
lines above fit one reading, that WeType 3.0 acts only on key events that did not come from another process (the
system stamps every posted event with the poster's pid, which no CGEvent post can hide). Not proven; the one
counter-example is the 00:10:38 success. If that reading holds, no CGEvent post from Hijack can start WeType 3.0's
voice input, and the ways out are a key that looks physical (Option B, Karabiner's virtual keyboard, a dependency on
the running Karabiner-DriverKit-VirtualHIDDevice daemon), another voice tool, or WeType 2.x.

### Owner test about 17:10 and the way out (W11)

With「快捷键全局生效」on, a physical Fn in Squirrel makes WeType switch itself in and listen; after the release the
input source stays WeType (owner: 停在微信输入法). So WeType 3.0 does the front half (switch in, listen) on a physical
key and rejects posted ones; the back half (switch back, ADR 0003) is what is left for Hijack. Option B is closed for a
user app: Karabiner's virtual-keyboard daemon socket is root-only, and an own DriverKit HID device needs an Apple
entitlement. W11 adds follow mode (docs/adr/0024): the trigger is the talk key, nothing is posted, Hijack remembers the
source at the press, watches the window after the release, and switches back.

### Field result on the first follow-mode install (2026-10-19 18:29 to 19:50)

Build 609ecdd (W11 key path only), `hijack set mode follow`, WeType's「快捷键全局生效」on. Two dictations, voice worked
both times, the input source was never switched back:

```
2026-10-19 18:36:23.995 dictation com.tencent.inputmethod.wetype.pinyin (follow): held 2.40s, window never closed after release, input source stayed, nothing to switch back | mic tool off device off, window while held: no window (pid 94224) | front=com.anthropic.claudefordesktop
```

At the check after the release the source was still Squirrel (so "stayed"); a TIS read at 18:40:40 and every one after
said WeType: it switched itself in later than the check. The second dictation (about 19:50) left no line at all. A 50 ms
poll of the selected input source (coordinating session, `ismon.swift`, a process with a run loop: without one
`TISCopyCurrentKeyboardInputSource` returns a stale value) shows `19:49:09 im.rime.inputmethod.Squirrel.Hans` and
`19:50:29.896 com.tencent.inputmethod.wetype.pinyin` with four `TISNotifySelectedKeyboardInputSourceChanged` posts
within 30 ms, while `hijack log --live` captured nothing for the press: WeType 3.0's tap, ahead of ours, swallows the
physical Fn too when it acts on it. Hijack never sees the key; the one signal it gets is the input-source change. The
owner was inside WeType from the first dictation on, so the second press was inside the voice source: passthrough,
nothing remembered, nothing restored. ADR 0024 items 7 to 9 (the tool's own switch-in starts the dictation, its
window or microphone ends it, the last other source is tracked) are the answer. Field lines on the builds that carry it:

```
2026-10-19 20:15:43.212 dictation com.tencent.inputmethod.wetype.pinyin (follow): switched in by the tool, window closed 968ms after start, input source unreadable at the press, nothing to switch back to | mic tool off device off, window seen: 1 window | front=com.anthropic.claudefordesktop
2026-10-19 20:37:30.168 dictation com.tencent.inputmethod.wetype.pinyin (follow): switched in by the tool, window closed 4337ms after start, back after 4.61s | mic tool on device off, window seen: 1 window | front=com.anthropic.claudefordesktop
```

The first (7ab277d) fired with the process started inside WeType and no other source seen since: WeType's window was
seen and closed 968 ms after the switch-in, nothing to go back to. The second (8901461, the tracked source persisted;
the owner had switched to Squirrel once before): the window closed 4.34 s after the switch-in, Hijack switched back to
Squirrel 4.61 s after it (owner: 切回来了; a TIS read afterwards said `im.rime.inputmethod.Squirrel.Hans`). The
per-process mic read on this time. Status: resolved for WeType 3.0 by follow mode; the hold path stays for the other tools.

### Next, for the owner

1. `settingfunction_voiceInputExclusiveMode` has no stored value in any of WeType's settings files and no label in its
   bundle: no user-facing switch was found. A hold-to-talk key other than Fn is behind the same Accessibility gate
   (WeType's own panel says so), so it was not tried; it is still the one cheap experiment left.
2. Decide between Option B (post through Karabiner's virtual keyboard), another voice tool (Sogou, Doubao, Handy are
   already providers), or WeType 2.x.
3. Still open: the fault before 10-17 (10-04, 10-06, 10-11, with WeType 2.x) is not explained by this; from now on its
   lines will carry `ahead:` and say whether a listener was in front then too.
