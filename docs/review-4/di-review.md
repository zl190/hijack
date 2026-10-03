# Independent review: seams, fault injection, FMEA actions 1-6

Scope: branch `di-fault-injection`, 7 commits from merge-base a329863 to 18f9f50.
I reviewed `git diff main...HEAD` (three dots): 27 files, +1878/-619.
`git diff main..HEAD` (two dots) also shows 4 newer doc commits on main as reverts (`docs/hci-review-faults.md`, FMEA cells).
Those reverts are not part of the branch. `git merge-tree` reports a clean merge.

Method:
- I read every changed source file, and main's `Sources/Engine.swift` and `Sources/Watch.swift` for comparison.
- I read `Sources/Shared.swift`, `AppState.swift`, `Config.swift`, `Providers.swift`, `CLI.swift` for the live seam targets.
- I compared the hot path line by line with main.
- I did not build, install or launch the app. The lead ran `swift test` and `./build.sh`.
- I copied `Sources/Core` and the tests to a scratch folder. I added three probe tests there, and all three failed as predicted (M1, S1, S3).
- I measured FSEvents traffic on `~/Library/Application Support` for 30 s on this Mac (S4).

Baseline: review-3 says the tap callback shares the main thread with all other work (`docs/review-3/senior-review.md:6`).
Every extra cost on the main thread can delay keys and cause `tapDisabledByTimeout`.

---

## 1. Behavior equivalence (paths the FMEA did not change)

| Check | Result | Evidence |
|---|---|---|
| Tap callback work per key event | Same, with one small regression (S6) | `System.swift:101-117` against main `Engine.swift:361-378`. `KeyInput` reads keycode, user data and flags (`System.swift:78-79`). Main read the same fields. No new system call. No new file I/O. |
| Marker echo, `swallowUp`, `paused`, repeat filter, flag matching, `physicalDown` | Identical | `Core/Engine.swift:349-379` against main `Engine.swift:311-341`, line for line. Only the event type changed (`KeyInput`). |
| Tap-disabled path | Changed by Action 2 | `Core/Engine.swift:323-339`. It adds one `tapIsEnabled` call per disable. On failure it writes `state.json` inside the callback (S5). |
| Summary line | Byte-identical on old paths | `Core/Engine.swift:270-290` against main `Engine.swift:271-289`. New text only at `:238`, `:240`, `:281-282`. Stats parses both (`Core/Stats.swift:53-62`). |
| `refresh()` only between sessions | Unchanged | Guard `Core/Engine.swift:81`. Callers: `Menu.swift:22`, `Core/Engine.swift:167`, `:394`. Same as main. |
| Switch to voice | Equivalent | Main used `DispatchQueue.main.async` (main `Engine.swift:189`). The branch uses `asyncAfter(.now() + 0)` (`Core/Engine.swift:181`, `System.swift:135`). It still runs before the 0.02 s talk-key poll. |
| `switchTo` | Identical | `Core/Engine.swift:142-148` against main `InputSource.swift:31-37`. |
| Sampling off main | Identical | `Core/Engine.swift:252-266`, `System.swift:137-139` against main `Engine.swift:253-267`. |

---

## 2. Findings

### Must-fix

#### M1. Action 4 breaks the FM-17 chain: a fast second dictation leaves the user in the voice IME
- `Core/Engine.swift:176` sets `previous = nil` on `.begin`.
- `SessionMachine.swift:67`: a press in `waitingForText` returns `[.finishPrevious, .swallowKey, .begin, .switchToVoice, .scheduleTalkKey]`.
- `Core/Engine.swift:174`: `.finishPrevious` writes the summary only. It does not restore the source.

Failure scenario:
1. The user dictates from ABC. `previous` is ABC. The source is now WeType.
2. The user presses again while the first dictation waits for its text.
3. `.begin` clears `previous`. `.switchToVoice` reads WeType, so `previous` stays nil (`Core/Engine.swift:178-179`).
4. The second dictation ends with "started inside WeType, nothing to switch back to" (`Core/Engine.swift:240`).
5. The user stays in WeType. The next typing goes through the voice IME.

This applies to toggle mode and to every hold-mode setup where the shortcut is not the talk key (`Core/Engine.swift:156-158`).
On main, the chain restored to ABC, as FM-17 says (`docs/fmea.md`, row FM-17: "the new one restores to the older `previous`").
FM-17 has O=3. The retry after a failed dictation is exactly this pattern.

Evidence: a scratch test (press, release, press again at +0.5 s, release) ends with the source WeType.
The sources list was `[wetype]`. The second summary says "started inside WeType".

Fix (smallest): consume `previous` in `finish()`, not at `.begin`.
- Remove `previous = nil` from `Core/Engine.swift:176`.
- At the top of `finish()` (`Core/Engine.swift:237`), write `let prev = previous; previous = nil`, and use `prev` below.
- `testFM07_PreviousResetsPerDictation` (`FI2SourcesTests.swift:66-75`) still passes, because the first dictation's `finish()` clears it.
- Add an FM-17 engine test: the chain must end in ABC.

### Should-fix

#### S1. Action 5 can strand the user in the voice IME when the switch completes late
- `Core/Engine.swift:203-206` gives up at `maxSwitchWait` (1 s).
- `Core/Engine.swift:238` then returns from `finish()` with no restore.
- `switchTo` retries once, at +0.1 s only (`Core/Engine.swift:144-147`).

Failure scenario: TIS is slow after wake (FM-06 cause). The select completes at 1.2 s.
Hijack has already ended the dictation. Nothing switches back. The user types into WeType.
Before Action 5, the talk key went out late and `finish()` restored the source.
Action 5 trades an S4 row (FM-05) for a new S3 path, like FM-16.

Evidence: a scratch test sets the source to WeType after `switchFailed`. After 5 s the source is still WeType.

Fix: in the `switchFailed` branch, select `previous` again when it is set.
For example: `if let prev = previous { clock.after(0.5) { if sources.current() == p.voiceID { switchTo(prev, "restore") } } }`.
Add a test: a late switch ends in the original source.

#### S2. Action 1 cannot tell a stuck modifier from a key the user holds, and its live check is unverified
- `Core/Engine.swift:314`: `guard !physicalDown`. At `start()`, `physicalDown` is always false. The guard never blocks.
- `System.swift:92` reads `CGEventSource.flagsState(.hidSystemState)`.
- `Core/Engine.swift:316` checks the generic flag. Left Option held matches a Right Option talk key.

Failure scenario A: Hijack restarts (update relaunch, `hijack restart`) while the user holds Option or Fn.
Hijack posts a release (`Core/Engine.swift:318`). Apps see the modifier go up while the finger is still down.
The modifier works again only after the user presses it again.

Failure scenario B: it is not shown that a synthetic Fn down, posted by a dead process, appears in `hidSystemState`.
If it does not, Action 1 never fires for FM-10. `FakeTap.modifierIsDown` (`Fakes.swift:70`) assumes that it does.
FI-4 (`FI4KeysTests.swift:41-47`) therefore tests the fake's assumption, not the system.

Fix (smallest): record a breadcrumb when the talk key goes down, and clear it when it goes up.
Write it off the main thread, because `endVoice()` runs inside the tap callback.
At `start()`, release the key only when the breadcrumb says the previous process held it.
Also measure once on a real Mac which state table (`hidSystemState` or `combinedSessionState`) shows a posted Fn.

#### S3. Action 3 can stop a dictation that started after the wake
- `Menu.swift:35` and `Menu.swift:41` call `reconcileAfterWake` on `didWake` and on `screenIsUnlocked`.
- `Core/Engine.swift:305-308` stops any active session. It does not check when the session started.

Failure scenario: the Mac has no lock on sleep. The user opens the lid and starts a dictation at once.
`didWakeNotification` arrives after the press. Hijack stops the new dictation (`run(.release)`) while the user talks.
Evidence: a scratch test starts a session, then calls `reconcileAfterWake`. The state becomes `waitingForText`.
The delay of `didWakeNotification` after wake is not measured. Thus this is a hypothesis about the timing, not about the code.

Fix: record `generation` on `willSleep` and on `screenIsLocked` (`Menu.swift:30`, `:38`).
In `reconcileAfterWake`, stop the session only when `generation` is still that value.
The FM-25 tests (`FI1TapTests.swift:75-102`) cover `listening` only. FMEA action 3 asks for "each active state". Add `starting` and `passthrough`.

#### S4. SettingsWatch now watches large, busy folders for most users
- `Core/Watch.swift:21` and `:63-68` climb to the nearest existing ancestor for every watched path.
- `Menu.swift:21` watches the config file plus both voice tools' files (`Providers.swift:145`).
- `Providers.swift:117-118`: the Handy folder is `~/Library/Application Support/com.pais.handy`.

Failure scenario: a WeType user without Handy gets a recursive file-level stream on all of `~/Library/Application Support`.
A Handy user without WeType gets the same. Without `~/.config`, the stream covers the whole home folder.
Each batch runs on the main queue (`Core/Watch.swift:41`), next to the tap. It bridges a `CFArray` and filters paths (`:27-28`).
The header promise "Idle: no timers, no wake-ups" (`Core/Watch.swift:5`) no longer holds.
Measured on this Mac, 30 s, mostly idle: 32 batches, 44 paths. Under browser or build load the rate is higher. I did not measure that.
FM-18 (`docs/fmea.md`, row FM-18) concerns the config folder only.

Fix (smallest): create `~/.config/hijack` at launch, which FMEA action 6 already allows.
Keep the climb for the config folder only, or drop it. For voice-tool folders, keep main's filter (main `Watch.swift:14-16`).

#### S5. Action 2 writes `state.json` synchronously inside the tap callback
- `Core/Engine.swift:330` calls `sink.state` from `reenableTap`, which runs in `handle()` in the callback (`:343-345`).
- `AppState.swift:16-21` creates a folder, encodes JSON and writes a file atomically, on the calling thread.

Failure scenario: the tap was disabled because the main thread stalled. The first re-enable fails.
The callback now does file I/O at the worst moment. Review-3 finding 2 describes the same pattern for `log()`.

Fix: move the first `sink.state(...)` into the `clock.after(0)` block at `Core/Engine.swift:331`.

#### S6. `trace` is eager again, which undoes the review-3 finding 1 fix
- Main: `trace` takes `@autoclosure` (`Shared.swift:44`). The string is built only while someone streams the debug log.
- Branch: `Sink.trace(_ msg: String)` (`Seams.swift:72`) and `Engine.trace` (`Core/Engine.swift:77`) take a built `String`.
- `Core/Engine.swift:163` formats the state change and `effects.map { "\($0)" }` on every trigger edge, inside the tap callback.
- `Core/Engine.swift:138` builds `forwardKey.name`, which calls `localize` and `Locale.preferredLanguages` (`Shared.swift:13-20`), on every dictation.

The cost is small (no I/O). But it is a silent regression on the thread that the tap shares.

Fix: declare `func trace(_ msg: @autoclosure () -> String)` in `Sink` and in `Engine`. `LiveSink` passes `msg()` into the existing `trace`.

### Nits

- **N1.** A hand-edited `holdDelay` above 1 s fails every dictation with a false message. `Core/Engine.swift:201-206` checks `waited >= maxSwitchWait` when the source is ready. `Config.swift:61` does not clamp. The UI and CLI clamp to 1 s (`Settings.swift:441`, `CLI.swift:235`). Fix: `else if !ready && waited >= maxSwitchWait`.
- **N2.** On `switchFailed`, "held" is the time to failure, not the hold. `Core/Engine.swift:164-165` sets `releasedAt` at `switchFailed`. `:272` uses it. Stats records `heldMs` from it (`Core/Stats.swift:65`).
- **N3.** `Core/Engine.swift:322` says "state.json tells the menu". Only the CLI reads it (`CLI.swift:121`, `:144`). The menu surface is HCI work that is still open. After a failed retry there is no further attempt (`Core/Engine.swift:331-336`). One retry with backoff, as in `start()` (`:396`), costs little.
- **N4.** `FakeClock.offMain` runs inline (`Fakes.swift:13`). Live, the result arrives on a later main-queue turn (`System.swift:138`). No test can see a release between the sample and its result.
- **N5.** `testFM18_ChangesOutsideTheWatchedFoldersDoNotCount` (`WatchTests.swift:27-37`) also passes when the stream never starts. The FSEvents tests depend on real timing (3 s timeout, `WatchTests.swift:23`).
- **N6.** `scripts/diagrams.sh:15` passes `Sources` and `Sources/Core`. Every Core type appears twice in `classes.puml` (for example `Engine` at `:154` and `:553`). This predates the branch, but the branch doubles more types.

---

## 3. Test quality

Each Action has one assertion that fails when the Action is reverted:

| Action | Test | Assertion that fails on revert |
|---|---|---|
| 1 | `testFM10_StuckModifierIsReleasedAtStart` | `FI4KeysTests.swift:45` (one release of key 63) |
| 2 | `testFM02_FailedReenableIsRetriedAndReported` | `FI1TapTests.swift:39` ("re-enable failed, retrying") |
| 3 | `testFM25_WakeDuringHoldStopsTheSession` | `FI1TapTests.swift:80-82` (when the method body is empty) |
| 4 | `testFM07_PreviousResetsPerDictation` | `FI2SourcesTests.swift:73` (no third select) |
| 5 | `testFM05_NoSwitchMeansNoTalkKey` | `FI2SourcesTests.swift:13` (no talk key) |
| 6 | `testFM18_FolderCreatedAfterTheWatchStartsIsSeen` | `WatchTests.swift:23` (timeout) |

The FI tests assert FMEA effects, not fake bookkeeping: keys posted, final source, machine state, and the parsed Stats cause.

Gaps:
- No engine test covers FM-17. A test there would have caught M1.
- Action 1 tests encode a live assumption (S2). No test covers a key the user holds at launch.
- Action 3 tests cover `listening` only (S3).
- Action 2 has no test for "still disabled after retry" (`Core/Engine.swift:335`).
- Action 5 has no test for a late switch (S1).
- `testFM26_OtherKeysCostNoSystemCall` (`FI1TapTests.swift:130-138`) passes on main's code too. It is a characterization test. It does not reach `LiveTap`, where the per-event cost lives (`System.swift:101-117`). It counts probe and source calls, not tap or sink calls. It skips the trigger, and a trigger press reads TIS inside the callback (`Core/Engine.swift:158`, unchanged from main).
- Most FM-01/04/08/09 tests also pass on main. They pin behavior across the refactor. That is useful, but they do not verify an Action.

FakeClock against the live queue:
- Order: equal deadlines run in FIFO order (`Fakes.swift:17`). That matches `DispatchQueue.main` for one-off work.
- Drift: the fake has none. Live polls drift by handler time. Tight windows such as `FI3ProbesTests.swift:16` (2.5-2.55 s) are valid for the fake only.
- `after(0)` inside `advance` runs in the same `advance`. Live, it runs on the next turn. The tests use `advance(0)` for that turn (`FI1TapTests.swift:14`). That is correct.

---

## 4. Thread safety

No finding.
- `sampleWhileHeld` sends only `pids`, `watched` and `probes` off main (`Core/Engine.swift:255-259`). `LiveProbes` is a value with no state (`System.swift:125-130`).
- Engine state changes only in the `done` closure (`Core/Engine.swift:260-264`). `LiveScheduler` runs it on main (`System.swift:138`).
- `localize` is a global `var` (`Seams.swift:9`). `main.swift:10` sets it once, before the app starts any thread.

---

## 5. Package and build

- Core imports only Foundation, CoreGraphics, os and CoreServices (`Core/Keys.swift:1-2`, `Core/Engine.swift:1-3`, `Core/Watch.swift:1-2`). There is no AppKit.
- FSEvents in Core is acceptable. CoreServices needs no AppKit, and the tests drive the real stream (`WatchTests.swift:5`).
- The callback pointer is correct now. With `kFSEventStreamCreateFlagUseCFTypes` (`Core/Watch.swift:39`), `eventPaths` is a `CFArray` of `CFString`.
- `Core/Watch.swift:27` reads it unretained. FSEvents owns the array for the duration of the callback, so unretained is correct.
- Main never read the pointer (main `Watch.swift:19`), so main was not wrong, only blind to paths.

---

## 6. Docs and diagrams

- Acceptance 11 (`docs/state-machine.md:37`) matches `SessionMachine.swift:77` and `:82-83`. `SessionMachineTests` covers it (`+11` lines in that file).
- `docs/diagrams/states.mmd` adds `starting --> idle: switchFailed`. This matches the table.
- `docs/diagrams/architecture.mmd` adds the seams node. `classes.puml` lists `reconcileAfterWake`, `clearStuckModifier`, `reenableTap` (`:199-201`) and `SettingsWatch.roots`/`counts` (`:318-320`).
- The doubled types are N6.

---

## Verdict

**Merge after fixes.**

The refactor keeps the hot path equivalent. The seams are small and honest. Each Action has a test that fails on revert.

Fix M1 before merge. It turns the common retry pattern (FM-17) into a stranded input source, which is the FM-16 effect.
Fix S1 and S5 in the same pass, because both are small.
Fix S2, S3, S4 and S6 before the 1.1.4 soak run (FMEA action 7). Otherwise the soak data will show effects that this branch added.
