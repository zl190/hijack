# Independent review: seven hardening commits

Scope: branch `lint-swift-format`, the seven hardening commits in `git log main..HEAD`.

| Commit | Subject |
|---|---|
| 43b19bc | Release the talk key on quit, at the source (FM-10) |
| 0c5f900 | Add a single-instance guard before NSApplication starts |
| 86c54b5 | Make the Watch tests deterministic with an injectable FolderEvents seam |
| b9127ac | Carry a build identity through CFBundleVersion |
| 3e3ac24 | Move the mid-dictation settings refresh off the tap callback |
| 8e8f540 | Log the summary line by stable id, not a localized display name |
| 1d9d4b8 | Escape config.json strings and clamp timing values on load |

Method:
- I read `git show` of each commit, and the surrounding code at HEAD.
- I read `Engine.swift`, `SessionMachine.swift`, `main.swift`, `Menu.swift`, `System.swift`, `Stats.swift`, `CLI.swift`, `Config.swift`, `build.sh`, `Makefile` and the relauncher plist.
- I compared against `docs/review-4/sparkle-review.md` (S6) and `docs/review-5/senior-audit.md` (items 3, 14, 17).
- I did not build, install, launch or kill the app. The lead ran `swift test` (118 pass) and `./build.sh`.
- I copied `Package.swift`, `Sources`, `Tests` and `docs/diagrams` to a scratch folder. The 118 tests pass there.
- In the scratch copy I ran two probe tests (P1, P2) and four mutations (§3).
- I linked a 15-line program against the pinned Sparkle 2.10.0 framework (`.sparkle/2.10.0`). It calls `SUStandardVersionComparator` (§2 M2).

---

## 1. Questions from the brief, short answers

| # | Question | Answer | Evidence |
|---|---|---|---|
| 1a | Acceptance line for `quit` | Yes, line 12. | `docs/state-machine.md:24`, `:39` |
| 1b | Every state × `quit` has an outcome | Yes. Test 10 runs every (state, event, mode). Line 12's "elsewhere nothing" has no behavior assertion (S1). | `SessionMachineTests.swift:81-93`, `:116-125` |
| 1c | One release in hold mode | Yes, synchronous. | `Engine.swift:105-107`; `HCIFaultsTests` `testStopForQuit_ListeningReleasesTheTalkKeyOnce` |
| 1d | Right stop in toggle mode | No, for a tap or double-tap tool. The stop tap is scheduled, and the process exits first (M1). | P1 |
| 1e | Nothing when idle or in passthrough | Yes. Idle: the `isActive` guard. Passthrough: `(_, .quit)` returns no effect. | `Engine.swift:385-388`, `SessionMachine.swift:82` |
| 1f | Menu Quit, `pkill -x Hijack`, logout | Reasoning only, no manual check is recorded. Quit calls `terminate:`. SIGTERM reaches `terminate:` through the dispatch source. Logout sends the quit Apple event. Info.plist has no `NSSupportsSuddenTermination`. | `Menu.swift:131`, `:290`; `main.swift:32-35`; `build.sh:66-84` |
| 1g | SIGTERM source order and queue | Correct. `SIG_IGN` comes first, then the source on `.main`, both before `app.run()`. The source is a global, so it stays alive. | `main.swift:32-37` |
| 1h | SIGKILL, crash | Not covered, as expected. `clearStuckModifier()` clears the key at the next start. Nothing restarts Hijack after a crash. | `Engine.swift:364-371` |
| 1i | `kill -INT` | Not covered. Default action: the process dies with the talk key down (S2). | `main.swift:32` |
| 2 | Settings apply before the next press | Not always. A press that comes before the deferred turn runs one whole dictation on the old plan (S3). | P2 |
| 2b | Double refresh | Rare and harmless. `refresh()` rejects the extra call while the key is down. | `Engine.swift:83`, `:178` |
| 3a | Placement after the CLI | Correct. `hijack status` still works. | `main.swift:13-22` |
| 3b | Race of two starts | Open. Both can run, or both can exit (S4). | Reasoning, §2 S4 |
| 3c | Relauncher, M4 "Reopen" | The relauncher runs `pgrep` first, so the guard does not change it. The M4 path and `make install` can lose to an instance that is still exiting (S4). | Relauncher plist line 18; `Menu.swift:348-355`; `Makefile:38-41` |
| 3d | `exit(0)` before NSApplication | Safe. No app state exists yet. | `main.swift:21` |
| 3e | Log line reaches the file | Yes. `logInApp` is false, so `log()` writes synchronously. | `Shared.swift:45-65` |
| 4 | Stats on old and new lines | Yes. The parser takes any tool string. The CLI maps ids to names. `logID` uses no `localize`. | `Stats.swift:47`; `CLI.swift:303`; `Keys.swift:55-58` |
| 5a | Is `+dirty` valid for Sparkle | Yes. It parses as a trailing text part. `1.2.0.abc1234+dirty` < `1.2.0.abc1234`. | Comparator probe |
| 5b | Does `make release` refuse a dirty tree | No (M3). | `Makefile:57-69` |
| 5c | Same-VERSION order | Random, by the hex letters of the sha (M2). | Comparator probe |
| 6 | Escaping, ranges, log, round trip | Correct for quotes, backslashes and control characters. One range copy is left in Settings (S5). | `ConfigValues.swift`; `Settings.swift:479-486` |
| 7 | FolderEvents seam | Live behavior is the same. `deinit` releases the stream. The live test honors `HIJACK_SKIP_LIVE_TESTS`. | `Watch.swift:28-58`; `WatchTests.swift:60-73` |
| 8 | Tests fail on revert | Yes for the main test of each Core change. Two tests are guards that pass on revert (N8). | §3 |

---

## 2. Findings

### Must-fix

#### M1. Quit during a toggle dictation with a tap-style tool posts nothing: the voice tool keeps listening
- `stopForQuit()` runs `.quit`, which returns `.releaseTalkKey` from `listening` (`SessionMachine.swift:80-81`).
- `.releaseTalkKey` calls `endVoice()`. For style `tap` or `doubleTap`, `endVoice()` calls `tapKey()` (`Engine.swift:105-107`).
- `tapKey()` posts the key down in `clock.after(delay)` and the key up 0.03 s later (`Engine.swift:91-97`). Both are main-queue blocks.
- `terminate:` calls `exit()` right after `applicationWillTerminate` returns. The main queue does not run again.
- WeType gives style `tap` or `doubleTap` when only its toggle shortcut is set (`Providers.swift:39`).

Failure scenario:
1. WeType has only a toggle shortcut. The user starts a dictation. WeType listens, and the mic is on.
2. The user quits Hijack from the menu, or runs `pkill -x Hijack`.
3. The stop tap never goes out. WeType keeps the mic on after Hijack is gone.
4. A second case: the quit comes within 30 ms of a start tap. The key down went out, the key up did not. The key stays down (FM-10 itself).

Evidence (P1): Rig with `style = "tap"`, toggle on, in `listening`. `stopForQuit()` posts 0 events synchronously. After `clock.advance(0.1)`, it posts 2.
The Rig plan is always `style: "hold"` (`Fakes.swift:142-145`). So no current test covers this path.

Smallest fix:
- Give `endVoice` a synchronous form for quit: post down, `usleep(30_000)`, post up. For `doubleTap`, do it twice with a 0.12 s gap.
- Also post a pending key up synchronously: keep a flag "tap key down not yet up" in `tapKey()`, and release it in `stopForQuit()`.
- Test: Rig with `style = "tap"`, quit in `listening`. Assert two posts (down, up) with no clock advance.

#### M2. `CFBundleVersion = VERSION.sha` gives builds of the same VERSION a random order in Sparkle
- `build.sh:12-14` writes `CFBundleVersion` as `VERSION.sha`, plus `+dirty`.
- `generate_appcast` copies `CFBundleVersion` into `sparkle:version` (`Makefile:89`). Sparkle compares that with the host `CFBundleVersion`.
- The Sparkle wiring is already on this branch, so the "separate ticket" in `build.sh:10-11` is this branch.
- `docs/review-4/sparkle-review.md` S6 says S6 "must be settled before the `<VERSION>.<sha>` branch lands". The commit lands it unsettled.

Evidence, from Sparkle 2.10.0's `SUStandardVersionComparator` on this Mac:

| A | Result | B |
|---|---|---|
| `1.2.0.abc1234` | > | `1.1.4` |
| `1.2.0.5a669c3` | > | `1.2.0.abc1234` |
| `1.2.0.e5a1b2c` | < | `1.2.0.9f00000` |
| `1.2.0.1234567` | > | `1.2.0.abc1234` |
| `1.2.0` | > | `1.2.0.abc1234` |
| `1.2.0.abc1234+dirty` | < | `1.2.0.abc1234` |

Different VERSION values still compare correctly. Builds with the same VERSION compare by the sha characters: a digit beats a letter.

Failure scenario:
1. The maintainer commits the real Sparkle key. From then on, every source build has an updater (`Menu.swift:31-34`).
2. Release `1.2.0.5a669c3` is in the feed. A later source build is `1.2.0.abc1234`, installed with `make install`.
3. Sparkle says the release is newer. It offers the older build as an update, and an install replaces the newer source build.
4. The reverse order hides an update in the same way.

Smallest fix (as S6):
- Keep `CFBundleVersion` numeric and increasing, for example `git rev-list --count HEAD`. Or use `VERSION` alone.
- Put the sha and `+dirty` in a custom key, for example `HijackCommit`.
- `hijack version` and `hijack status` print `HijackCommit` (`CLI.swift:41`, `:46`, `:133`).

#### M3. `make release` publishes a dirty tree: the zip need not match the tag
- `release-checks` checks only the tag on HEAD, the GitHub release, the identity and the key file (`Makefile:57-69`).
- The key check reads the working file `assets/sparkle-public-key.txt`, not the committed file (`Makefile:67`).
- `release-assets` then runs `./build.sh` on the working tree.

Failure scenario:
1. For 1.2.0, the maintainer pastes the public key into `assets/sparkle-public-key.txt`, and forgets to commit it.
2. `make release` passes every check. The build is `1.2.0.<sha>+dirty`.
3. The published zip contains code that is not at the tag. The appcast publishes `+dirty` as `sparkle:version`.
4. The next 1.2.0 build from the clean tag compares as newer than the shipped one (row 6 of the table in M2).

Smallest fix: add one check to `release-checks`:
`@test -z "$$(git status --porcelain)" || { echo "The tree has uncommitted changes. Commit or stash them before you release."; exit 1; }`

### Should-fix

#### S1. Acceptance line 12's "elsewhere `quit` shall change nothing" has no behavior test
- `testQuitStopsImmediatelyWithoutWaitingForText` checks `listening`, `starting` and `idle` only (`SessionMachineTests.swift:117-125`).
- Mutation: `(.waitingForText, .quit) → (.idle, [.finish])`. Only `testStateDiagramIsCurrent` fails.
- Mutation: `(.passthrough, .quit) → (.idle, [])`. Only `testStateDiagramIsCurrent` fails.
- `HIJACK_UPDATE_DIAGRAMS=1` rewrites the diagram, and then that guard is silent. Commit 43b19bc did exactly that for its own edges.

Fix: loop as test 11 does. For each state other than `starting` and `listening`, assert the same state and `[]`, in all five modes.

#### S2. SIGINT and SIGHUP still kill the process with the talk key down, and a quit leaves no log line
- Only SIGTERM goes to `terminate:` (`main.swift:32-35`).
- Ctrl-C on a binary run from a terminal sends SIGINT. The maintainer runs the app that way.
- `stopForQuit()` writes nothing to the log (`Engine.swift:385-388`). A field log cannot show that a quit released a key.
- The commit records no manual check of the SIGTERM path. The claim "a kill or a launchd stop also runs applicationWillTerminate" is reasoning only.

Fix:
- Route `[SIGTERM, SIGINT, SIGHUP]` through the same loop: `signal(s, SIG_IGN)`, then one source for each, kept in a global array.
- In `stopForQuit()`, log `quit: stopped the session in <state>` before `run(.quit)`.
- Manual check: hold Fn in a dictation, run `pkill -x Hijack`, read the last log line.

#### S3. A press that comes before the deferred refresh runs one whole dictation on the old settings
- `run()` now schedules `refresh()` with `clock.after(0)` (`Engine.swift:178`).
- When the next press is handled first, `physicalDown` is true, and `refresh()` returns early (`Engine.swift:83`).
- `run(.press)` reads `plan` before any refresh (`Engine.swift:161`).
- Before 3e3ac24, the refresh ran at the end of the release, so the next press always saw the new plan.

Evidence (P2): app mode. The plan changes mid-dictation (`holdDelay` 0.2 → 0.9). Release, then press before `clock.advance(0)`. The second dictation runs with 0.2. After it, the plan has 0.9.

The window is small. It opens when the main thread is busy and the next press is already queued. The code comment at `Engine.swift:175-177` says the change applies "now", which is too strong.

Fix (root cause): make `makePlan()` free of file I/O. Read the provider's settings file in the `SettingsWatch` callback, off the tap, and cache the result in `Model`. Then `refresh()` can stay synchronous.
Fix (minimum): change the comment to say a press in the same run-loop turn keeps the old plan for one dictation. Add P2 as a test.

**Accepted, not fixed in this pass.** The window is one run-loop turn (`clock.after(0)`), open only when the main thread is already busy and the next press is already queued at the moment the previous dictation ends — a dictation that then runs on the just-superseded settings for one more press, not indefinitely. The root-cause fix (caching the provider's settings off the tap, in `Model`) is a larger change than this pass's scope; the minimum fix (a corrected comment, plus P2 as a regression test) is deferred to the same follow-up as S4(a)-(c) in the verdict below. No code or test change for S3 in this pass.

#### S4. The single-instance guard can leave zero or two instances
- `main.swift:18-22` asks `NSRunningApplication` for another process with the bundle id. It is a check, then an exit, with no lock.
- (a) Two copies start within the same few milliseconds. Neither is registered yet: both run, with two taps.
- (b) Two LaunchServices launches. `NSRunningApplication` lists apps that are still launching (that is why `isFinishedLaunching` exists). Each sees the other, and both exit. This is reasoning, not tested.
- (c) An instance that is still exiting counts as running. SIGTERM is now a graceful `terminate:` (43b19bc), so the exit takes longer.
  - `make install` runs `pkill`, `rm`, `cp`, then `open` (`Makefile:38-41`).
  - M4 "Reopen" waits 0.5 s, then runs `open -b` (`Menu.swift:352`).
  - If the old process is still there, the new one exits, and no Hijack runs.
- (d) A second copy at another path, for example `open build/Hijack.app` while `/Applications/Hijack.app` runs, exits silently. The maintainer then tests the old binary. Only the log line tells.

Fix:
- Take an exclusive `flock` on `~/Library/Application Support/Hijack/instance.lock` with `LOCK_EX | LOCK_NB`. The kernel releases it when the process dies, also on SIGKILL.
- When the lock is held, wait up to 2 s for it, so an exiting instance can finish.
- When it is still held, print one line to stderr with the other pid and its bundle path, and activate the other instance, then exit.

#### S5. The timing ranges still have a third copy in the Settings window
- `Settings.swift:479`, `:482`, `:486` use the literals `0.05...1`, `1...15`, `0.5...10`.
- The commit says the constants in `ConfigValues.swift:18-20` are the "single source of truth".

Fix: use `holdDelayRange`, `restoreTimeoutRange` and `fallbackDelayRange` in the three steppers.

### Nit

- N1. Quit from `starting` leaves the user in the voice IME when the switch already happened. `finish()`'s `sources.select` is synchronous, so `(.starting, .quit) → (.idle, [.finish])` restores it. That also writes a summary line, which a quit dictation has none of today (`SessionMachine.swift:80-81`).
- N2. The summary line still carries a localized name in one end text: "started inside \(p.voiceName)" (`Engine.swift:261`). Stats does not parse it, so the count does not split. The test checks one path only.
- N3. `hijack stats --json` now keys `tools` by the localized display name (`CLI.swift:303`, `:306`). Machine output changes with the language. Keep the ids in JSON, and add a `toolNames` map if needed.
- N4. `logID` gives `keyCode42` for an unnamed key. `KeySpec(binding:)` does not parse that form, unlike the comment says (`Keys.swift:53-58`, `:81-96`). Add a round-trip test: `KeySpec(binding: k.logID) == k` for named keys and combos.
- N5. An old line with an English name merges with a new id line only when the UI is in English (`CLI.swift:300-303`). Under Chinese, "WeType" (old) and "微信输入法" (new) stay two rows. The comment says they merge.
- N6. The clamp log line repeats in each `hijack` CLI process and after each config change, until the file is fixed (`Config.swift:62-69`). Acceptable; consider one save of the clamped value.
- N7. `testJSONLiteral_PlainStringRoundTrips` says "an empty string" but tests `"plain"`. No test has non-ASCII text, for example `"微信输入法"` (`ConfigValuesTests.swift:21-25`).
- N8. Two new tests pass with their change reverted: `testRefreshPlan_ToggleReleaseStayingActiveSchedulesNothing` and `testParsesTheNewIdBasedFormatTheSameAsTheOldNameBasedOne`. They are guards, not revert detectors. That is fine; the commit messages should not list them as mutation evidence.
- N9. `HIJACK_SKIP_LIVE_TESTS` is set nowhere (`Makefile`, `.github`). Name it in `docs/usage.md` or the test target note. `LiveFolderEvents.start` called twice would drop the first stream without a release (`Watch.swift:31-53`); nothing calls it twice today.

---

## 3. Tests: what fails on revert

| Commit | Test | Fails on revert? | Assertion | Source |
|---|---|---|---|---|
| 43b19bc | `testQuitStopsImmediatelyWithoutWaitingForText` | Yes | effects `== [.releaseTalkKey]` | commit mutation 1 |
| 43b19bc | `testStopForQuit_ListeningReleasesTheTalkKeyOnce` | Yes | `keys.count(Rig.fn, down: false) == 1` | commit mutation 1 |
| 43b19bc | `testStopForQuit_IdleDoesNothing` | Yes, for the guard | `sink.traces.count` unchanged | commit mutation 2 |
| 43b19bc | `quit` in `waitingForText` / `passthrough` | Only the diagram test | — | my mutations (S1) |
| 0c5f900 | none | — | process-level, no test | — |
| 86c54b5 | `WatchTests` (5) | Yes for roots and forwarding | `watch.roots`, `fake.startedRoots`, `changed == 1` | read |
| b9127ac | none | — | shell and CLI only | — |
| 3e3ac24 | `testRefreshPlan_IsDeferredOffTheReleaseInAppMode` | Yes | `planReads == before` (got 3, expected 2) | my mutation |
| 3e3ac24 | `testRefreshPlan_ToggleReleaseStayingActiveSchedulesNothing` | No (guard) | — | N8 |
| 8e8f540 | `testSummaryLine_CarriesStableIdsNotLocalizedNames` | Yes | `hasPrefix("dictation \(Rig.voice) (")`, `contains("fn sent after")`, `!contains("WeType")` | my mutation |
| 8e8f540 | `testSummaryLine_TooShortAlsoUsesTheStableKeyId` | Yes | `contains("released before fn was sent")` | my mutation |
| 8e8f540 | `testParsesTheNewIdBasedFormat…` | No (guard) | — | N8 |
| 1d9d4b8 | `testJSONLiteral_AStringWithAQuoteRoundTrips`, `…BackslashesAndControlCharacters…` | Yes | round-trip equality | commit mutation 1 |
| 1d9d4b8 | `testClampedTiming_OutOfRange…`, `…BelowRange…` | Yes | clamped value, log line | commit mutation 2 |

Missing tests that the findings need: tap-style quit (M1), line 12 "elsewhere" (S1), press before the deferred refresh (S3), `logID` round trip (N4).

---

## 4. Verdict

**Merge after fixes.** Fix M1, M2 and M3 before the first `make release` of 1.2.0.
- M1 breaks the commit's own claim for every tap-style tool, and can leave the mic on after quit.
- M2 is review-4 S6, now on the release path, confirmed against the pinned Sparkle.
- M3 is one line in `release-checks`.

S1-S5 can follow in 1.2.1. S4 (a)-(c) should be settled before Sparkle relaunches are common.
The FolderEvents seam, the summary ids and `jsonLiteral` are correct as they are.
