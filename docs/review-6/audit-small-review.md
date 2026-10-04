# Independent review: audit-small (review-5 items 7, 8, 13, 16, 18, 19)

Scope: branch `audit-small`, `git diff main..HEAD`, 6 commits (9767f3f to bbbe057), 10 files, +268/-45.
Motivation: `docs/review-5/senior-audit.md`, items 7, 8, 13, 16, 18, 19.

Method:
- I read every changed file and the code around each change: `Engine.handle` (`Sources/Core/Engine.swift:505-525`),
  `LiveScheduler` (`Sources/App/System.swift:154-158`), `FakeClock` (`Tests/HijackCoreTests/Fakes.swift:13-35`),
  the key recorder (`Sources/App/Settings.swift:105-171`), the menu build (`Sources/App/Menu.swift:218-275`)
  and `applicationDidFinishLaunching` (`Sources/App/Menu.swift:40-125`).
- Mutation runs: I copied `HEAD` with `git archive` into a scratch folder (the worktree was not touched) and ran
  `swift test --filter 'MenuStateTests|KeyRecordingPause'` once per mutation. Results are in §3.
- Item 16: I built a scratch, ad-hoc-signed `.app` with one LaunchAgent plist in `Contents/Library/LaunchAgents` and
  read `SMAppService.agent(plistName:).status` without registering it. macOS 27.0, bundle in the scratch folder.
- Item 18: I ran a scratch AppKit program: an `NSTabViewController` with `.toolbar` style in a window. I changed
  `tabViewItem.label` and `image.accessibilityDescription` at run time and read back `window.toolbar.items`.
- Item 19: `git grep` on `HEAD` and `main` for each deleted name, for `Selector("`, `NSSelectorFromString` and
  `perform(`, and a search for nib, xib and storyboard files.
- I did not install, launch Hijack, push or tag. The lead's facts (170 tests, lint 0, build green, clean merge) stand.

---

## 1. Questions from the brief, short answers

| # | Question | Answer | Evidence |
|---|---|---|---|
| 8a | New work on the key path | None. `handle` still reads one stored `Bool` (`guard !paused`). Pause, resume and the timeout run on main through `Scheduler.after` (`DispatchQueue.main.asyncAfter`), the same thread as the tap callback, so `paused` has no race. | `Engine.swift:518`, `:437-453`, `System.swift:156-158` |
| 8b | Can a stale token resume a newer recording's pause | No. Every pause bumps `recordingToken`; a timeout clears `paused` only when its captured token is the current one. The bump in `resumeFromKeyRecording` is redundant (the next pause bumps too), but harmless. | `Engine.swift:440-452`; mutation 5 in §3 |
| 8c | Settings window closes while recording | `resume` runs at once: `windowWillClose` calls `stopRecording`, which calls `resumeFromKeyRecording`. The 30 s timer then fires and does nothing. | `Settings.swift:681`, `:153-155` |
| 8d | `recordingPaused` above the other faults | Not right when the key listener is off. See S2. | `MenuState.swift:41-42` |
| 8e | Boundary tests and mutations | Real. 29.0 s and 31.0 s both fail a test; the guard removal fails the stale-token test. One gap: `resumeFromKeyRecording` is not tested (S3). | §3 |
| 7a | Does `!AXIsProcessTrusted()` alone justify "the grant belongs to an older build" | No. See M1. | `Shared.swift:30-34`, `MenuState.swift:53` |
| 7b | Same text on three surfaces, through `L()` | Yes. Menu and Settings use `staleAccessibilityGuidance` (wrapped in `L()`); `hijack doctor` uses the English constant, as all CLI output is English. | `Menu.swift:246`, `Settings.swift:334`, `CLI.swift:179` |
| 16a | Status read before register | Yes. But a never-registered agent can report `.notFound`, and that case now does nothing. See M2. | `Menu.swift:103-118` |
| 16b | `.requiresApproval` surfaced | Main app: yes, a row with an "Open Settings…" button. Relauncher: one log line per launch. | `Settings.swift:535-539`, `Menu.swift:115-116` |
| 16c | Errors through `log()`, not `print` | Yes, all four call sites. | `Menu.swift:108`, `:114`, `Settings.swift:526` |
| 16d | Common `.enabled` case | Unchanged: no call when the plist did not change; unregister and register when it did. | `Menu.swift:110-114` |
| 16e | Re-register after the bundle path changes | Same as `main`. Neither version reads the bundle path; both re-register only on a plist change or a non-enabled status. Not a regression. | `Menu.swift:98-101` |
| 19 | The five deleted symbols had no callers | Confirmed. No hit for `toggleStopOnAnyKey`, `setLanguage`, `toggleIcon`, `toggleLogin` on `HEAD`. No `Selector("…")`, `NSSelectorFromString` or `perform(` in `Sources`. No nib in the app (only Sparkle's own). The App-level free `switchTo` had no caller; the remaining hits are `Engine.switchTo`, a different method in Core. The build proves the rest. | `git grep` |
| 13 | Labels match the visible titles | Yes. All nine `labelsHidden()` controls now carry the `L()` string of their row title. The steppers also get `accessibilityValue`. | `Settings.swift:306`, `:437`, `:476`, `:487`, `:531`, `:543`, `:553`, `:559`, `:580-581` |
| 18a | Rebuild on the right notification | Yes. A language change saves the config; `SettingsWatch` reloads `Config.shared` and then posts `.hijackSettingsChanged`, so `L()` already sees the new language. | `Menu.swift:48-52` |
| 18b | Do the toolbar items follow | Yes, tested: after a label change, `window.toolbar.items` labels and image descriptions read the new text; the title changes too. | scratch AppKit run |
| 18c | Observer leak, duplicate toolbar items | No duplicates: the code edits the existing items. One observer, because `SettingsWindowController.shared` is never released. The `deinit` does not remove that observer (N1). | `Settings.swift:625-627`, `:663`, `:683` |

---

## 2. Findings

### Must-fix

#### M1. The stale-grant text is false for a first-run user, and its first step is the one the audit says does not work

`Shared.swift:30-34`, used at `Menu.swift:246`, `Settings.swift:334`, `CLI.swift:179`.

The text says "Accessibility shows Hijack as allowed but the grant belongs to an older build. Turn it off and on again
in System Settings, or remove Hijack from the list and add it again." It shows for every `!AXIsProcessTrusted()`.
The code comment at `Shared.swift:23-26` agrees that this check cannot tell a first run from a stale entry.

Failure scenario 1 (first run, the most common case): a new user opens Hijack. `Menu.swift:121` opens Settings, and the
Try It card says the switch is already on and the grant belongs to an older build. Neither is true. The user finds
Hijack off, or not in the list, and the app has told them something false at the first contact.

Failure scenario 2 (the stale case the item is for): the audit (item 7) says "Toggling it does not help; only removing
the entry does." The new text offers the toggle first. The user tries it, nothing changes, and the text does not say so.

Smallest fix: one conditional sentence that is true in both cases, with removal as the stale-case step. For example:
"Turn on Hijack in System Settings › Privacy & Security › Accessibility. If it is already on, select Hijack, click −,
then add it again with +." Keep the Chinese the same meaning. Use a short menu form (see S4).

#### M2. A never-registered relauncher agent can report `.notFound`, and the new switch then never registers it

`Menu.swift:103-118`.

The old code registered for every status other than `.enabled`. The new code registers only from `.notRegistered`;
`.notFound` goes to `default: break` with no log line. In my scratch bundle on macOS 27.0, an agent plist that is in the
bundle and was never registered reports `.notFound`. `SMAppService.mainApp` reports `.notFound` there too.
Warrant gap: the scratch bundle was not in `/Applications`; I did not test a fresh install there.

Failure scenario: a fresh install. The status is `.notFound`, nothing registers, nothing is logged. The next update
through brew or `install.sh` replaces the app and nothing reopens it. That is the failure the relauncher exists for,
and it is now silent, which is the opposite of what item 16 asks for.

Smallest fix: `case .notRegistered, .notFound:` on the register branch. Add `@unknown default: log(…status…)` so a
future status is not silent. Update the comment at `Menu.swift:95-97`.

### Should-fix

#### S1. After the 30 s timeout, Settings still shows "Press a Key…" while the engine is live again

`Engine.swift:442-446`, `Settings.swift:109-115`, `:166-171`.

The timeout clears `Engine.paused` only. `SettingsStore.recording` stays set, the local monitor stays installed, and
the button still says "Press a Key… (Esc Cancels)". The menu no longer shows the recording line.

Failure scenario: the user clicks the recorder, switches app, comes back after 40 s and presses the current trigger
to record it again. The tap now swallows the trigger and starts a dictation (the exact case the pause exists to stop),
and the recorder never sees the key.

Smallest fix: give `Engine` an `onKeyRecordingTimeout: (() -> Void)?` that the timeout calls, and set it in
`SettingsStore` to `stopRecording`. The audit's other step (stop recording on `windowDidResignKey`) also fixes it.

#### S2. `recordingPaused` hides "key listener off"

`MenuState.swift:41-42`; test `MenuStateTests.testRecordingPausedWinsOverEverything` pins the order.

Recording uses a local `NSEvent` monitor, so it works with the tap off. With the tap off, the menu says "Recording a
shortcut; dictation paused". That tells the user dictation comes back when recording ends. It does not. The real
fault, which has the only fix action ("Reopen Hijack"), is hidden. The order also differs from
`docs/hci-review-faults.md` §3.2 and the comment at `Menu.swift:232-235` ("a dead key listener first").

Smallest fix: put `recordingPaused` after `keyListenerOff` (and, if wanted, after `stillHolding`). Change the test to
assert `.keyListenerOff` when both are true.

#### S3. `resumeFromKeyRecording` has no test

`Engine.swift:450-453`. Mutation 7 in §3 (`paused = false` changed to `paused = true` in `resume`) survives all tests.
No test calls `resume` and then checks that dictation works again.

Smallest fix: one test: `pauseForKeyRecording()`, `advance(5)`, `resumeFromKeyRecording()`, then
`XCTAssertFalse(r.press())` and `XCTAssertNotEqual(machine.state, .idle)`.

#### S4. The menu line is one 170-character item

`Menu.swift:246`. Menu items do not wrap, so the whole menu becomes very wide. The old item also ended with "Allow…",
which told the user that the item is clickable; the new item does not.

Smallest fix: a short menu text that ends in an action word, for example
"⚠︎ Accessibility is off for Hijack — Open Settings…". Keep the full text in Settings and `doctor`.

### Nits

- N1. `Settings.swift:683`: `removeObserver(self)` does not remove an observer added with
  `addObserver(forName:object:queue:using:)`; only the returned token does. No effect today (the controller lives for
  the life of the app, and the closure holds `self` weakly). Keep the token and remove it, or delete the `deinit`.
- N2. `Settings.swift:623`, `:658-661`: the `symbol` field of `tabSymbols` is never read. A plain array of title closures
  is enough. The tab titles are now written twice (`:646-649` and `:658-661`); one list could feed both.
- N3. `Menu.swift:232-235`: the comment lists the fault order and does not mention `recordingPaused`.
- N4. `MenuState.swift:46-53` and `Shared.swift:23-28`: the comments say `hijack doctor` uses
  `showsStaleAccessibilityGuidance`. It does not; `CLI.swift:179` reads `st.trusted` directly. The two tests for it
  pin a single `!`; they do not catch a change in wording or a surface that stops using the helper.
- N5. `Engine.swift:452`: the token bump in `resume` is redundant (mutation 5 survives). Keep it as defense, but the
  comment should say that the next `pause` also bumps.
- N6. Outside item 13: each `KeyRecorder` button reads as the key name only ("Right Option, button"), with no row
  title. `.accessibilityLabel` plus `.accessibilityValue(key.name)` would fix it.

---

## 3. Mutation results (scratch copy, `swift test --filter 'MenuStateTests|KeyRecordingPause'`)

| # | Mutation | Result | Test and assertion that fails |
|---|---|---|---|
| 1 | Delete `if recordingPaused { return .recordingPaused }` | Killed | `testRecordingPausedShowsAlone` (`XCTAssertEqual` nil vs `.recordingPaused`), `testRecordingPausedWinsOverEverything` |
| 2 | Timeout 30.0 to 29.0 | Killed | `testKeyRecordingPause_PressAt29_9SecondsIsStillIgnored` (`XCTAssertTrue(r.press())`, state `starting`) |
| 3 | Timeout 30.0 to 31.0 | Killed | `testKeyRecordingPause_ClearsAt30Seconds` (`XCTAssertFalse(paused)`), `…PressAt30_1SecondsRuns` |
| 4 | Delete the token guard in the timeout | Killed | `testKeyRecordingPause_StaleTimeoutDoesNotCancelANewerRecording` (`XCTAssertTrue(paused)`) |
| 5 | Delete the token bump in `resume` | Survived | Expected: the next `pause` bumps the token (N5) |
| 6 | Delete `paused = false` in the timeout | Killed | `testKeyRecordingPause_ClearsAt30Seconds`, `…PressAt30_1SecondsRuns` |
| 7 | `resume` sets `paused = true` | **Survived** | none (S3) |

The item 7 tests kill `{ !trusted }` to `{ trusted }` (the branch's own `scripts/mutate-check-review5-7.sh`); I did not
re-run it. No new test is vacuous, but the item 7 pair tests only a negation (N4).

---

## 4. Verdict

**Not ready to merge.** Fix M1 (the wording) and M2 (`.notFound`) first; both are small. Items 13, 18 and 19 are correct
as they are. Item 8 is correct on the key path and the token logic; S1 and S2 are the remaining gaps, and S3 is one test.
