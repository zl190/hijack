# Senior review: diagnostics since v1.1.1

Scope: `git diff v1.1.1..HEAD` (commits 6aa8349, 8b51586) and how they interact with `Sources/Engine.swift`.
Method: read every changed file plus `Engine.swift`, `Config.swift` (Model), `Providers.swift`, `Focus.swift`, `InputSource.swift`, `Keys.swift`, `CLI.swift`, `Menu.swift`; `./build.sh` succeeds (no warnings in the tail). Nothing was launched or installed.

Threading baseline (confirmed): the tap's run-loop source is added to the **main** run loop (`Engine.swift:244`). The tap callback, every `asyncAfter` poller, the 1 s config `Timer` (`Menu.swift:18`), the workspace observers, the settings window and the menu all share one thread. There are no data races inside the app. The cost is different: anything slow on the main thread delays every key on the system and can get the tap disabled by timeout. Many findings below follow from this.

---

## Confirmed findings (traced in code)

### 1. should-fix (high): "AX lookup moved out of the tap" still blocks the tap
- `Engine.swift:170` `DispatchQueue.main.async { log(line + " | \(focusDesc())") }`
- `Engine.swift:117` `trace("... \(focusDesc())")` in `forwardWhenReady`, on every dictation

**Failure scenario.** `focusDesc()` (`Focus.swift:7-18`) asks the system-wide AX element for the focused element. That call is synchronous IPC to the focused app. If that app is busy or hung, the call blocks for up to the AX messaging timeout, which defaults to about 6 s. The tap callback runs on the same main thread. Every key event queues behind the call, and WindowServer disables the tap with `tapDisabledByTimeout`. Moving the call from inside the callback into `main.async` changes *when* it blocks, not *what* it blocks. Also, `trace()` takes an eager `String`, so line 117 runs the AX call on every dictation even when nobody is streaming the debug log. The commit message says the AX call is "kept out of the tap callback". For the purpose that matters (tap latency), that is not true.

This is a plausible contributor to the observed `event tap was disabled by the system (timeout)` (see H1). In v1.1.1, `focusDesc()` ran *inside* `pressed()`/`released()` on every press.

**Fix.** Pick one:
- (simplest) Replace `focusDesc()` with `NSWorkspace.shared.frontmostApplication?.bundleIdentifier`. That needs no AX and no blocking IPC, and the AX role adds little to the summary.
- Keep AX but call `AXUIElementSetMessagingTimeout(sys, 0.05)` and run it on a background queue.

Either way, remove it from line 117, or make `trace` take `@autoclosure` and gate it on `OSLog(subsystem:category:).isEnabled(type: .debug)`.

### 2. should-fix (high): file I/O inside the tap callback, at the worst moment
- `Engine.swift:237-239` slow-event `log(...)` in the callback
- `Engine.swift:175` tap-disabled `log(...)` in the callback
- `Shared.swift:47-57` `log()` does: `stat`, maybe `remove` + `rename` (rotation), allocate a new `DateFormatter`, open, seek, write, close, plus an `os_log` call

**Failure scenario.** The slow-event line fires exactly when the main thread is already behind. A 2 s stall with 30 queued keystrokes produces 30 synchronous file writes in the callback. Each one makes the stall longer, which makes more events "slow". This is positive feedback toward `tapDisabledByTimeout`, and the probe makes the condition it measures worse. The tap-disabled handler also logs *before* it re-enables.

**Fix.** In the callback, record only numbers into a small struct and `DispatchQueue.main.async`, or a serial background logging queue, to write them. Rate-limit to one line per stall burst ("N slow events in burst, max queued X ms, max handled Y ms"). Re-enable the tap first, then log. Make `log()` cheap: one static `DateFormatter` (or `ISO8601DateFormatter`) with `en_US_POSIX`, and a single long-lived `O_APPEND` file descriptor on a serial queue.

### 3. should-fix (privacy): the slow-event line records the keycodes of arbitrary typing
- `Engine.swift:238` `key \(event.getIntegerValueField(.keyboardEventKeycode))`

**Failure scenario.** During any main-thread stall, every queued keyDown/keyUp, not just the trigger, is written with a millisecond timestamp to a file that persists in 1 MB + 1 MB. Text typed during a stall, including a password typed into a non-secure field (taps do not see Secure Input fields, but they do see everything else), can be partly reconstructed from consecutive lines. That is a keylogger-shaped artifact, and the docs tell users to share logs in issues.

**Fix.** Log a category instead of the code: `trigger`, `ours` (marker), `other`, plus the event type. Together with the burst aggregation in #2, this keeps the diagnostic value.

### 4. should-fix: a large hidden cost per event, made worse by the new echo check
- `Engine.swift:180` `m.forwardKey.code` for every marker event
- `Config.swift:116` `forwardKey` → `detectedVoiceKey` → `provider.detected()` → `weTypeVoice()` (`Providers.swift:12-40`), which **reads and parses WeType's MMKV file from disk on every access**
- `Config.swift:108` every `m.c` access calls `Config.reload()`, which `stat`s config.json (throttled to 2/s)

**Failure scenario.** Every `Model` property touched in the callback goes to disk. When no explicit voiceKey is set, each of our own posted Fn down/up echoes now does a full file read plus isoLatin1 decode plus backwards string search *inside the tap callback*. `pressed()` calls `m.forwardKey`, `m.voiceStyle` (another `detected()`), `m.toggleMode` and `m.provider` several times per press. With `trigger: "follow"` (the default in `docs/usage.md`), `handle()` line 192 evaluates `m.trigger`, and so reads WeType's file, on **every keystroke system-wide while idle**. Normally each read takes well under a millisecond. After wake, under disk pressure, or with FileVault and a cold cache it is unbounded, and it runs on the tap's thread.

**Fix.** Snapshot a `SessionConfig` (`trigger`, `forwardKey`, `voiceStyle`, `toggleMode`, `provider`, `voiceName`) once per session in `pressed()`. `trigger` is already snapshotted; extend that. Recompute the idle trigger only when config or the WeType file changes (mtime check on the 1 s timer), never per event. The echo check then compares against the snapshot.

The snapshot also fixes a pre-existing correctness bug. `startVoice()` and `endVoice()` each re-read `m.voiceStyle` and `m.forwardKey`. If config.json (CLI `hijack set`, a hand edit, or the 1 s timer reload) or WeType's settings change between press and release, the app can post Fn **down** and then a *tap* of a different key, or an up for a different key. That leaves Fn logically held down.

### 5. should-fix: the mic probe is sampled at the wrong moment and is not specific to the process
- `Engine.swift:118` sample at forward + 0.6 s, IME path only
- `Engine.swift:254-264` `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input device

**Failure scenarios.**
- **Short hold.** Forward happens at about holdDelay (0.2 s) after press, so the sample lands about 0.8 s after press. For any hold shorter than that, the sample runs *after* `endVoice()` posted Fn up, so `mic off` is expected and is reported as evidence that the IME didn't start. `gen == generation` does not protect against this, because `generation` only changes on the next press.
- **Not specific to WeType.** "Running somewhere" is true if *any* process holds the default input device: a Zoom/Teams/FaceTime call, a browser tab with the mic open, an audio interface monitor. In those states `mic on` is always reported, and it is also a false positive for "WeType started". If WeType records from a non-default device, the probe reads `off` while WeType records.
- **App provider (Handy).** `micOn` is never sampled on that path (`Engine.swift:91-95` has no sample). The summary always says `mic unknown`, yet that is the provider where mic is the *only* probe, because there is no window watch.

**Fix.**
- Sample at a deterministic point: in `released()` immediately *before* `endVoice()`, plus optionally once mid-hold. Record `nil` with the reason "held < probe delay" instead of a misleading `off`.
- Sample on both paths.
- On macOS 14.2+ (guard with `#available`, since the target is 13), use the per-process HAL objects: `kAudioHardwarePropertyProcessObjectList`, then `kAudioProcessPropertyPID` == WeType's pid, then `kAudioProcessPropertyIsRunningInput`. That measures "WeType is recording", which is the actual question. Keep the device-wide check as a fallback, labelled `mic(any)`.

### 6. should-fix: the window report is computed long after the moment it describes
- `Engine.swift:168` `windowReport()` runs inside `summary()`, which runs when `restoreWhenDone` gives up, i.e. `fallbackDelay` (2.5 s) after release
- `Engine.swift:137-146` `isBusy()` is polled only *after release*, never during the hold

**Failure scenario.** "window missing (pids X have 0 on-screen windows)" describes the screen 2.5 s after the user let go. By then a WeType capsule would be gone in a *working* session too, so the parenthetical carries almost no information about the failure. It also cannot tell "TIS bundle lookup returned nil" (the `isBusy()==nil` path the prior-art doc flags) from "no window" *at the time it mattered*. `sawWindow` is documented as "showed a window during this press", but it only covers the post-release polling window.

**Fix.** Make one probe the single source: `enum VoiceWindow { case noBundle, noProcess([String]), windows(pids:[pid_t], count:Int) }` returned by `InputMethodProvider.voiceWindows()`. Derive `isBusy()` from it, which removes the duplicated logic in `Providers.swift:75-91`. Capture it at the same moment as the mic sample (before `endVoice`). Also record the first post-release poll's result. Print those captured values in the summary instead of recomputing at the end.

### 7. should-fix: the echo probe proves less than the summary comment says
- `Engine.swift:179-181`, comment at `Engine.swift:161-162`

What it does measure (confirmed empirically by the failure log, which shows `echo seen`): an event posted at `.cghidEventTap` does come back through our own HID-level, head-inserted tap. So "echo seen" means the event entered the HID stream *and reached the first tap in the chain, ours*. It does **not** show that the event survived later taps (other remappers, BTT, Karabiner's grabber, etc.) or that the IME's input context received it. Read the failure ("echo seen, mic off, window missing") as "posted and entered the stream, and the IME did not react". It is not evidence that the IME received the key.

Two precision problems:
- **Any matching keycode counts.** Fn *up* from `endVoice()` sets `echoed = true`, so for a hold, a lost down plus a delivered up reads as "seen". The summary is built after release, so the up echo is always in time.
- **"echo missing" is ambiguous.** If the tap is disabled at that moment, which is the situation under investigation, our own events skip the tap too, so `echo missing` looks like "the key never went out" even though it was posted. `post()` also returns silently when `CGEvent(...)` fails (`Engine.swift:54`), which leaves no trace.

**Fix.** Record the echo of the *down* edge only: for modifier-only keys, a flagsChanged with the flag set; otherwise keyDown. Store its timestamp, so the summary can say "echo +3 ms". Log a line when `CGEvent` construction fails. Add `CGEvent.tapIsEnabled(tap:)` to the summary so "missing" can be disambiguated. Fix the comment to say what the probe proves.

### 8. should-fix: the commit says "lock" is logged, but it is not
- `Menu.swift:21-26`

`sessionDidResignActive` / `sessionDidBecomeActive` fire for fast user switching, not for screen lock. A screen lock with the password field (which also turns on Secure Event Input, prior-art §1f) produces no line. The prior-art doc's §4.1.6 asked for the distributed notifications.

**Fix.** Add `DistributedNotificationCenter.default()` observers for `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked`. While you're there, add `IsSecureEventInputEnabled()` to the summary line. It costs one call and is a known cause of "taps see nothing / IME disabled" (prior-art §1f-1h).

### 9. should-fix: a missed key edge desyncs the state machine, and an unmatched trigger key-up is swallowed (pre-existing, related)
- `Engine.swift:174-178`, `206-217`

**Failure scenario A.** The tap is disabled (timeout) while the trigger is held, and the release happens during the gap. `physicalDown`, `active` and `forwarded` stay true. **Fn stays logically down** (we posted Fn down, no up). The input source is not restored. The user's *next* press is swallowed. Its release finally runs `released()` (`down && !physicalDown` is false, so only the up edge acts). The result is one dead press, and WeType sits with Fn held in between. This is the Handy #840 pattern.

**Failure scenario B.** The trigger *down* passes during the gap and the *up* arrives after re-enable. `physicalDown` is false, `down` is false, so no branch runs, `pass = passthrough = false`, and line 217 returns `nil`. **The Right Option key-up is swallowed after the system saw its key-down.** The window server's modifier state now has Option stuck. Every later event, including our posted Fn flagsChanged as seen by apps reading the current modifier state, can carry ⌥ until the user presses Option again.

**Fix.** On `tapDisabledBy*`:
1. Re-enable.
2. Reconcile with `CGEventSource.keyState(.hidSystemState, key: trigger.code)` and `flagsState`. If our state says down but the hardware says up, run the release path. If `forwarded`, post the forward-key up.
3. Bump `generation`.

In `handle()`, pass through any trigger edge that does not match `physicalDown` (`!down && !physicalDown` → pass) instead of swallowing it.

### 10. nit → should-fix: concurrent writers (app + CLI) on rotation and append
- `Shared.swift:49-56`; the CLI writes via `log("cli: set ...")` (`CLI.swift:242`)

**Failure scenarios.**
- **Rotation.** Both processes see `size > logLimit`. The app renames to `.old.log`. The CLI then `removeItem(old)`, deleting the 1 MB just rotated, and renames the brand-new file. History is lost.
- **Append.** `FileHandle.seekToEndOfFile()` followed by `write` is not atomic across processes (no `O_APPEND`). Interleaved writers overwrite each other's line.
- **Create fallback.** `line.write(to:atomically:true)` *replaces* the whole file whenever `FileHandle(forWritingTo:)` fails, not only when the file is absent. Two creators race, and one line is lost.

The likelihood is low (CLI `set` is rare), but the fix is small.

**Fix.** Only the app rotates. The CLI either appends with `open(O_WRONLY|O_APPEND|O_CREAT)` or doesn't write to the file at all; the app already logs `config: reloaded` when it sees the change. Use `O_APPEND` for every write.

### 11. nit: `hijack log -f` goes silent after rotation
- `CLI.swift:264` uses `tail -f`, which follows the descriptor. After rotation it keeps following `Hijack.old.log`. Use `tail -F`.

### 12. nit: superseded sessions produce no summary line
- `Engine.swift:138` `guard gen == generation else { return }`

If the user presses again while the previous restore is still waiting (up to `restoreTimeout` = 5 s), the earlier session ends without a line. For a "one line per dictation" log, a retry-after-failure pattern (the exact case under investigation) loses the failed attempt's record. **Fix:** log a short "superseded by a new press" summary there.

### 13. nit: timing and units in the slow-event probe
- `Engine.swift:234,238` "waited N ms for the main thread": `entered - event.timestamp` also includes HID→WindowServer→tap delivery, so it is the event's age, not purely main-thread wait. Rename it to `age`. The mach-ticks interpretation of `CGEventTimestamp` matches observed behaviour on Apple silicon, but Apple documents the field as nanoseconds. Mark the probe as empirical in the comment, or cross-check once against `ProcessInfo.systemUptime`.

### 14. nit: log format and consistency
- `Shared.swift:53` `MM-dd` has no year, and the 1 MB + 1 MB retention can span New Year. Use ISO 8601 with offset (the prior-art doc asked for this). A locale-dependent `DateFormatter` without `en_US_POSIX` prints non-Gregorian digits or years for some users.
- Key names in the log are localized (`KeySpec.name` → `L(...)`), so the same event logs "右 Option" or "Right Option" depending on the UI language. Use `NamedKey.id` in logs, so a log shared from a zh system greps the same as one from an en system.
- The file holds the focused app's bundle id for every dictation, which is a usage history. That is acceptable, but `docs/usage.md` should say it, next to "Review logs before sharing them". The os_log `privacy: .public` on debug-level trace is fine: it is not persisted unless someone streams or enables it.

### 15. nit: naming and structure
- `fnAfter` is the forward key's latency, and the key isn't always Fn (Sogou is Left Option, Handy is a combo). Rename it to `forwardedAfterMs`.
- `textIn` ("text in 0.42s") is when the voice window disappeared, a proxy for commit. Name it for what it measures: `windowGoneAfter`.
- Five loose session fields (`pressedAt`, `sawWindow`, `echoed`, `micOn`, `fnAfter`) are reset by hand in `pressed()`. Put them in a `struct DictationRecord` with `var record = DictationRecord()` in `pressed()`, so new probes can't miss the reset, and give it a `summaryLine()` method. That also replaces the stringly `end:` parameter that is assembled at three call sites.

---

## Hypotheses (not proven by code reading)

**H1. Main-thread stall → tap timeout.** The callback shares the main thread with AX (#1), TIS (`select`/`currentID` are cross-process), `CGWindowListCopyWindowInfo` every 50 ms for up to 5 s, per-event disk reads (#4) and SwiftUI. The recorded `tapDisabledByTimeout` is consistent with this, and v1.1.1 ran `focusDesc()` inside the callback on every press and release. It does **not** by itself explain a *persistent* failure, because the tap is re-enabled and later echoes are seen. But #9 shows how one timeout can leave Fn or Option logically stuck. A cheap way to test: run the tap on a dedicated thread (`CFRunLoopGetCurrent()` in a `Thread`) whose callback only decides pass/swallow from a snapshot and hops to main for everything else. That is the standard structure for this problem.

**H2. A stuck modifier from #9B.** It would make WeType's push-to-talk check (Fn *alone*) fail on later presses even though our Fn echo is seen, and a process restart would not by itself clear WindowServer modifier state. That contradicts "fresh process fixes it", unless the user also happened to press Option. Rank it below H1 and H3. It is checkable: log `CGEventSource.flagsState(.combinedSessionState)` and `.hidSystemState` right after posting Fn down (prior-art §4.1.3, not implemented).

**H3. The implicit `nil` event source going stale in a long-lived process.** This is unverified (prior-art §1). It is the most direct match for "same binary, fresh process works" together with "echo seen, IME ignores". A/B test it with a held `CGEventSource(stateID: .hidSystemState)` rebuilt on wake.

**H4. Secure Event Input** held by another process after unlock. Prior art says this would be system-wide, so it would not fit "fresh process fixes it". Logging `IsSecureEventInputEnabled()` (#8) costs one call and settles it.

---

## Simpler shape that does the same job

One `DictationRecord` per press, filled at fixed points:
- **press:** time, secure input, `tapIsEnabled`, frontmost app via NSWorkspace
- **forward:** latency, down-edge echo
- **just before `endVoice`:** mic, per-process if available; window probe enum
- **first post-release poll:** window probe
- **restore or supersede:** outcome

Write it once from main via a serial logging queue. The callback stays pure: read the snapshot, decide pass or swallow, and record a few integers. That removes #1-#7 and #12-#15 in one structural change, and it is fewer lines than the current spread of `trace`/`summary`/`windowReport`.

---

## Verdict

**Merge-worthy as diagnostics, with fixes before relying on them.** Ranked:
1. The probes over-claim in ways that will misattribute the next failure: short-hold mic `off`, any-process mic `on`, the window report taken 2.5 s late, echo counting the up edge.
2. Two changes make tap timeouts *more* likely, which is the condition being diagnosed: AX on main every dictation, and synchronous file I/O in the callback during stalls.
3. The slow-event line logs keycodes of arbitrary typing.

Fix #1-#5 before the next soak run. Otherwise the data it produces will be ambiguous exactly where the investigation needs it.
