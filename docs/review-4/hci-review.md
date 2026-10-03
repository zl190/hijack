# Independent review: HCI fault signals (branch hci-faults)

Scope: `git diff di-fault-injection..HEAD` in `hijack-hci`, 5 commits on e8c7dba, 13 files, +361/-25.
Spec: `hijack/docs/hci-review-faults.md` §5, filtered by the owner decision in §5a.
In: item 1 without the notification; the item 2 "still holding" line; the two false "Try it" texts; item 4; the `usage.md` step.

Method:
- I read every changed file, and the parts of `Engine.swift`, `SessionMachine.swift`, `System.swift` and `Settings.swift` that the change calls.
- I did not build, install or launch the app. The lead ran the 83 tests and `./build.sh`.
- I checked one Foundation behavior with a scratch program. A `.main` observer runs inline when the post comes from the main thread. The order was `before post, observer, after post`.
- I viewed both icon PNGs, enlarged 8×.

---

## Findings

### Must-fix

#### M1. The icon shows "Off" after every normal launch
- `Menu.swift:18` calls `applyAppearance()` → `updateIcon()` before `engine.start()` (`Menu.swift:27`).
- At that moment no tap exists. `LiveTap.isEnabled` returns false (`System.swift:89`). The icon is "Off".
- `engine.start()` posts `.hijackStateChanged` through `LiveSink.state` (`Engine.swift:456`, `System.swift:148-152`).
- The observer for that notification is added later (`Menu.swift:49`). Nobody receives the post.
- Only a settings change calls `updateIcon()` again (`Menu.swift:24`, `:285`, `Settings.swift:89`).

Effect: a working Hijack shows the slashed icon, and its accessibility name is "shortcut not working" (`Menu.swift:126`).
This is the false surface that §5a forbids ("a surface that says something false must change").
The Accessibility-grant path is not affected, because `start()` retries 1 s later, after the observer exists (`Engine.swift:446`).

Fix: add the `.hijackStateChanged` observer before `engine.start()`. Or call `updateIcon()` after it.

#### M2. On the app path, every dictation end does file I/O inside the tap callback
- `Menu.swift:52-53`: on phase "done", the observer calls `writeSecureInputState()`.
- `writeSecureInputState()` (`Menu.swift:132-136`) calls `IsSecureEventInputEnabled`, `AXIsProcessTrusted`, `CGEventTapIsEnabled` and `NSWorkspace.frontmostApplication`. Then it calls `AppState.write`.
- `AppState.write` reads `state.json`, decodes it, calls `kill`, creates a folder, and writes the file atomically (`AppState.swift:38-46`).
- For an app tool (Handy), the stop runs `.finish` inside the key event (`SessionMachine.swift:60-63`). `finish()` reports "done" at once (`Engine.swift:257`).
- A `.main` observer runs inline when the post comes from main (scratch check above). So all of this runs inside the tap callback, on the release, for every Handy dictation.
- The new Accessibility guard has the same problem. It calls `sink.state` directly in the callback (`Engine.swift:373-376`). That writes `state.json` and redraws the icon inline (`System.swift:148-152`, `Menu.swift:49`). The S5 fix moved that write off the callback for the retry path (`Engine.swift:384`).

Fix: in the observer, write `DispatchQueue.main.async { self?.writeSecureInputState() }`. In the Accessibility guard, wrap `sink.state` in `clock.after(0)`.

#### M3. The "still holding" line shows for every toggle dictation, and misses the hold-mode case it exists for
- `Menu.swift:162`: `engine.machine.isActive && !engine.physicalDown`.
- Toggle mode: the shortcut is up during a normal session (`SessionMachine.swift:70-71`). The menu says "Hijack is still holding Fn — Release" during a good dictation. The click stops it (`Engine.swift:366-369`).
- §3.2 limits this line to hold mode. It gives toggle its own line, without a click.
- Hold mode: after a missed release, `physicalDown` stays **true** (the tap never saw the up). So the condition is false in the exact stuck case.
- When `reconcile()` sets `physicalDown` to false, it also ends the session (`Engine.swift:328-329`). The condition is effectively unreachable in hold mode.
- `stopStuckSession()` (`Engine.swift:366-369`) leaves a stale `physicalDown` true. Then the user's next press is a "repeat" and the engine swallows it (`handle`, `down == physicalDown`).
- The talk-key name comes from `m.forwardKey` (`Menu.swift:162`), not from the engine's plan snapshot.

Fix:
- Condition: `!engine.plan.toggle && engine.machine.isActive && !engine.tap.keyIsDown(engine.plan.trigger.code)`. This is one call, at menu open only.
- In `stopStuckSession()`, set `physicalDown = tap.keyIsDown(plan.trigger.code)` after the stop, as `reconcileAfterWake` does (`Engine.swift:348`).
- Name the key with `engine.plan.forwardKey.name`.
- Move the condition into Core, and test both modes.

#### M4. "Reopen Hijack" probably quits Hijack and does not reopen it
- `Menu.swift:304-305`: `openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())`, then `NSApp.terminate(nil)` at once.
- `OpenConfiguration.createsNewApplicationInstance` is false by default. Hijack is still running when LaunchServices handles the request, so LaunchServices activates the running copy. Then the app quits.
- The relauncher LaunchAgent watches the binary, not the process (`Menu.swift`, comment after `:54`). It does not restart the app.

Effect: the only recovery click for FM-02 leaves the user with no Hijack at all.
I did not run this. One manual click on a build confirms it or clears it.

Fix: set `createsNewApplicationInstance = true` and terminate in the completion handler. Or run `/usr/bin/open -n <bundle>` with a short delay, then terminate.

### Should-fix

#### S1. A sample that finishes after the release can rewrite "Try it"
- The sample's result closure checks only `gen == generation` (`Engine.swift:283`). It does not check the state.
- Now it reports to the UI (`Engine.swift:288-291`).
- A sample that starts before the release can finish after it. It then sets "Listening…" (with moving bars, `Settings.swift:309`) or "isn't listening yet…" after "Done talking…".
- On the app path, the dictation is already over. The text then stays until the next dictation.
- `FakeClock.offMain` runs inline (`Fakes.swift:13`), so no test can see this.

Fix: report only when `machine.state == .listening`.

#### S2. The Accessibility guard can make a short trust glitch permanent, and nobody has seen the event it waits for
- `Engine.swift:373-377` returns without `tap.enable()` and without a retry when `AXIsProcessTrusted()` is false.
- If the call reads false for a moment, the tap stays off for good. Nothing re-enables it, even after trust is true again.
- §6 of the spec says it is unknown whether macOS sends a tap-disabled event when Accessibility is revoked. If it does not, this guard never runs.
- The menu-open write corrects `state.json` with live values (`Menu.swift:156`, `:132-136`). `state.json` therefore does not flap. It follows the live state.

Fix: in the guard, still call `tap.enable()`. Poll `trusted` every 1 s, as `start()` does (`Engine.swift:444-447`). When trust returns, re-enable the tap and write `true/true`.

#### S3. The Secure Input line names the front app, which may not hold Secure Input
- `Menu.swift:163` and `:135` use `NSWorkspace.frontmostApplication`.
- Secure Input belongs to the process that turned it on. A background app (a password manager, a stuck terminal) can hold it while another app is in front.
- The line then blames the wrong app. Spec §6: if Hijack cannot name the owner, it uses "另一个 app" / "Another app".

Fix: always use "Another app", or find the owner pid first.

#### S4. The restore check can report "Didn't switch back" for a retry that worked
- `Engine.swift:151-153` reads `sources.current()` right after the retry `select`.
- The first check waits 0.1 s for exactly this reason (`Engine.swift:147-149`).
- Effect: a false negative in "Try it", which is a false text like the one this change removes.

Fix: check again 0.1 s after the retry, then call `confirmed`.

#### S5. The "Off" icon slash merges into the silhouette
- `scripts/make-off-icon.swift:30-33` strokes opaque black with `.copy` blend.
- A template image uses only alpha. Opaque black on an opaque silhouette changes nothing.
- The comment says "like a real cutout". The code does not cut. At 8× the result reads as a hat with a stick, not a crossed-out hat (`assets/HijackMenuTemplate-Off@2x.png`).

Fix: first stroke a wider line with alpha 0 (`.copy`, clear color) to cut a gap. Then stroke the narrower opaque line.

#### S6. Every menu open writes `state.json` on the main thread
- `Menu.swift:156` calls `writeSecureInputState()` on each open. That is a file read, then an atomic file write (`AppState.swift:38-46`).
- It does not run inside the tap callback. But the tap shares the main thread with the menu.

Fix: write only when a value differs from the last write, or write on a background queue.

### Nits

- **N1.** The unconfirmed-restore text (`Engine.swift:268`) is new wording. §3.3 has a text for the same fact (FM-16 row): "没能切回\(prev)，现在还是\(voice)。请用输入法菜单切换". The cause table is Out, but one fact should have one text.
- **N2.** "notListening" is reported again every 0.5 s while the mic stays off (`Engine.swift:289`). Report it once per dictation.
- **N3.** The "done" report now comes 0.1 s after `finish()` (`Engine.swift:265`). A press inside that 0.1 s gets "Switching…", and then the late "done" text replaces it. The window is narrow.

---

## Checks that pass

| Question | Result | Evidence |
|---|---|---|
| `micOffSince` adds no work to the tap callback | Pass | Runs in the sample's result closure on main (`Engine.swift:282-292`). It uses values already sampled. No new system call. |
| Restore confirmation adds no work to the tap callback | Pass | `finish()` on the IME path runs from the poll (`Engine.swift:227`). The report runs in `clock.after(0.1)` (`Engine.swift:148`). |
| A 1.1.3 `state.json` still decodes | Pass | Custom `init(from:)` uses `decodeIfPresent` for both new keys (`AppState.swift:31-32`). Encoding stays synthesized. A 1.1.3 CLI ignores the extra keys. |
| `state.json` stays atomic, on one thread | Pass | Still `.atomic` (`AppState.swift:45`). All writers run on main: `start`, the retry (`Engine.swift:384`), menu open, the "done" observer. |
| Icon sizes and template flag | Pass | `-Off.png` is 18×18 and `-Off@2x.png` is 36×36 (sips). `isTemplate = true` applies to both sources (`Menu.swift:124`). |
| SF Symbol only as fallback | Pass | `Bundle.main.image(forResource:) ?? NSImage(systemSymbolName:)` (`Menu.swift:122-123`). `build.sh` copies both PNGs (`build.sh:25`). |
| "Try it" mic-off text matches §3.3, through `L()` | Pass | `Settings.swift:56` matches "\(voice)还没开始听…" / "\(voice) isn't listening yet…". The bars stop, because they run only on "Listening…" (`Settings.swift:309`). |
| Menu lines match §3.2 | Pass | FM-02, "still holding" and FM-03 texts at `Menu.swift:170-174` match §3.2 character for character, through `L()`. |
| `hijack status` / `doctor` text | Pass | `CLI.swift:122-123`, `:146` match §3.4 and §5 item 4. |
| `usage.md` step | Pass | `docs/usage.md:43`. §6 still marks the manual step as unverified. |

---

## Test quality (16 new tests, `Tests/HijackCoreTests/HCIFaultsTests.swift`)

| Test | Fails on revert? | Assertion |
|---|---|---|
| `testIconIsOffUnlessBothTrustedAndTapActive` | Yes, if `IconState.of` changes | `:11-13`. It does not test the wiring, where M1 is. |
| 5 × `MenuFaults` priority tests (`:17-44`) | Yes, if the order changes | `:23`, `:28`, `:33`, `:38`, `:43`. They test the order, not the condition at `Menu.swift:162`, where M3 is. |
| `testFM24_AccessibilityRevokedWhileRunningWritesState` | Yes | `:55` (the message), `:56` (`[false, false]`) |
| `testStopStuckSession_HoldMode` | Yes | `:67`. The setup sets `physicalDown = false` (`:64`). A real missed release leaves it true (M3). |
| `testStopStuckSession_ToggleMode` | Yes | `:76` |
| `testStopStuckSession_NoSessionDoesNothing` | **No** | Without the guard, `run(.release)` in `idle` only swallows the key and posts nothing. `:83-84` still pass. |
| `testFM09_MicOffForASecondReportsNotListening` | Yes | `:97` |
| `testFM09_ABriefMicBlipDoesNotReport` | **No**, control | With the feature removed, no report exists. `:107` passes. |
| `testFM09_UnknownMicNeverReportsNotListening` | **No**, control | Same as the blip test (`:115`) |
| `testFM16_DoneReportWaitsForConfirmationThenConfirms` | **No** | At 2.4 s the dictation has not ended, so `:124` passes on the old code too. `:127` also passes on the old code. Check at 2.55 s, after `finish()` and before the 0.1 s confirm. |
| `testFM16_DoneReportSaysSoWhenNotConfirmed` | Yes | `:137` |

12 of 16 fail on revert. Two controls are correct as controls, but they prove nothing alone.
`testStopStuckSession_NoSessionDoesNothing` and `testFM16_DoneReportWaitsForConfirmationThenConfirms` are vacuous.
No test covers the toggle-mode menu condition (M3), the launch icon (M1), or code placement relative to the tap callback (M2).

---

## Verdict

**Do not merge yet. Merge after M1-M4.**

M1 and M3 make the menu bar say something false on the normal path. That is the failure this branch exists to remove.
M2 puts file I/O back into the tap callback on every Handy dictation, which repeats review-3 finding 2.
M4 can turn the FM-02 recovery click into a quit.
All four fixes are small. Fix S1-S4 in the same pass. They are one-line or two-line changes.
