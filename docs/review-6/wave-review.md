# Independent review: engineering wave W1-W5 (and ADR 0021 for W6)

Scope: branch `wave-w5`, `git diff main..HEAD`, 24 commits (b50809a to 85b9dc7), 62 files, +1836/-817.
Spec: `docs/engineering-wave-spec.md` §2-§3. Motivation: `docs/review-5/senior-audit.md`.

Method:
- I read every changed source, script and doc file, and `docs/state-machine.md`, `Sources/App/main.swift`, `Sources/App/Shared.swift`.
- W1: I read the compiler arguments of the release build from `.build/out/Intermediates.noindex/XCBuildData/*/task-store.msgpack`.
  I ran `otool -L` and `otool -l` on the SwiftPM binary and on the `build/Hijack.app` binaries in the sibling worktrees
  (`hijack`, `hijack-w2`, `hijack-w4` are swiftc builds; `hijack-swiftpm`, `hijack-w3`, `hijack-w5` are SwiftPM builds).
  I compiled a one-line file with `swiftc -O` in a scratch folder to see which rpaths swiftc adds by itself.
- W3: I searched the OS MetricKit binary (in the dyld shared cache) for its JSON key strings.
  I ran a scratch Swift program to check the day key in three time zones.
- W4: I read `gh release view` for the latest public release (assets only).
- I did not edit source, run `swift test`, run a mutation script, install, launch, push or tag.
  The lead's facts (146 tests, `make lint` 0, `make build` green, clean merge) stand.
  Where a finding rests on reading only, it says so.

---

## 1. Questions from the brief, short answers

| # | Question | Answer | Evidence |
|---|---|---|---|
| 1a | Optimization level | Equal or better. Both modules compile with `-O -whole-module-optimization`. The old call was `swiftc -O` with no `-wmo` (per-file batch mode). No `-Onone`, no `-enable-testing`, no `-DDEBUG` in the release build. | task-store: `-module-name Hijack -O -whole-module-optimization`, same for `HijackCore` |
| 1b | Target | Same: `arm64-apple-macos13.0` for both modules. | task-store `-target` |
| 1c | Module split cost | Core is now a separate module, so App-to-Core calls (the tap callback into `Engine.handle`) cross a module boundary. One call per key event; no measurable cost. | `Sources/App/System.swift:131` |
| 1d | Linked libraries | Same set; Sparkle stays `@rpath/Sparkle.framework/Versions/B/Sparkle`. | `otool -L` |
| 1e | Run paths | **Not equal.** SwiftPM adds `@loader_path` and an absolute path into `/Applications/Xcode.app`. See M1. | `otool -l` |
| 1f | `HIJACK_VERSION` into Info.plist | Yes. `build.sh:7` and the heredoc are unchanged; `HijackCommit` too. `.build/` is in `.gitignore`, so a build does not make the tree `+dirty`. | `build.sh:7-16`, `.gitignore` |
| 1g | `public` surface | No leak beyond the old single module (everything was `internal` in one module, so the app could reach it anyway). The split was a chance to narrow it; see N3. | `git diff main..HEAD -- Sources/Core` (216 `public` lines) |
| 1h | `Context.packageDirectory` | Absolute path to the package root. It works from any cwd and in CI. Paths with spaces are safe: `unsafeFlags` passes one array element per argument. | `Package.swift:7` |
| 1i | Sparkle before `swift test` in CI | Yes. `ci.yml` runs `make test`, and `Makefile` `test:` runs `scripts/fetch-sparkle.sh` first. A bare `swift test` on a fresh clone fails (N4). | `Makefile:25-27`, `.github/workflows/ci.yml` |
| 1j | `swift build --show-bin-path` | No flakiness found. It does not build; it prints the same configuration's folder. If it failed, `cp` gets `/Hijack`, fails, and `set -e` stops the build. | `build.sh:25-26` |
| 2a | Tap callback guard | Identical on the non-nil path: no new allocation, no log. The log runs only when `ctx` is nil. | `Sources/App/System.swift:122-127` |
| 2b | `postModifier` switch | Same key codes as the old dictionary (59, 58, 56, 55, 63). A new `Mod` case fails to compile. | `Sources/App/System.swift:56-65` |
| 2c | `Engine.sampleWhileHeld` | Same branches, same conditions. Off the tap path. | commit 51be263 |
| 2d | The 6 ignore reasons | True. `FI4KeysTests.testW5_QuickKeysAlwaysResolveToANamedKey` checks every id in `quickKeys`, which holds `right_option` and `fn`. `WatchTests.testLive_RealFSEventsSeesAWrite` exists. The comments name the class wrongly (N1). | `Tests/HijackCoreTests/FI4KeysTests.swift:94`, `WatchTests.swift:63` |
| 3a | Subscriber added once | Yes, in `applicationDidFinishLaunching`; `AppDelegate` holds it strongly. | `Sources/App/Menu.swift:39`, `:62` |
| 3b | Writes off main | Yes, on a utility queue. `jsonRepresentation()` runs on MetricKit's own callback thread. | `Sources/App/Metrics.swift:22-37` |
| 3c | 30-file cap | Works: names sort by time stamp. Small gaps in N5. | `Sources/App/Metrics.swift:41-49` |
| 3d | Parser shapes | Probably wrong for three of six fields. See S1. | `Sources/Core/MetricsSummary.swift:70`, `:79`, `:83`, `:92-97` |
| 3e | `doctor` crash rule | Compares against the last state write, not the last start. See S2. | `Sources/App/CLI.swift:210` |
| 4a | Property invariants | True, but two are weaker than the doc allows. See S8. | `Tests/HijackCoreTests/PropertyTests.swift:70-95` |
| 4b | SLO semantics | Correct. `met` is nil when nothing was judged. `0.99` exactly is met, and `99/100` gives the same double as the literal. Display rounding can mislead (N2). | `Sources/Core/Stats.swift:102-105`, `StatsTests` |
| 4c | Threat model cites | Stale after W1 and W5, and three rows are wrong. See S6. | §2 S6 |
| 5a | install.sh shell safety | Good: `set -e`, every path quoted, `trap` cleans the temp folder, every check stops before `/Applications`. Gaps: M2, S4, S5, N7. | `install.sh` |
| 5b | `pkill`/`ln` guard | Holds. Both run only when `HIJACK_INSTALL_DIR` is exactly `/Applications`. `scripts/test-install.sh` always sets a temp folder, so it never touches the real `~/.local/bin`. But `open` is not guarded (S4). | `install.sh:56-58`, `:66-72` |

---

## 2. Findings

### Must-fix

#### M1. The SwiftPM binary searches `/Applications/Xcode.app` for Sparkle before the bundle's own copy (W1 regression)

The release binary has four `LC_RPATH` entries, in this order:

```
/usr/lib/swift
@loader_path
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx
@executable_path/../Frameworks
```

- The swiftc builds have two: `/usr/lib/swift` and `@executable_path/../Frameworks` (`hijack/build`, `hijack-w2/build`, `hijack-w4/build`).
  A one-line `swiftc -O` probe also adds only `/usr/lib/swift`. So Swift Build adds the other two.
- The binary links Sparkle as `@rpath/Sparkle.framework/Versions/B/Sparkle`. dyld tries each rpath in order and loads the first file that exists.
- The binary needs nothing from the toolchain folder: `otool -L` shows no other `@rpath` library.
- The app has no hardened runtime (ADR 0021), so it has no library validation. A library with any signature loads.
- The installed `/Applications/Hijack.app` (HijackCommit `7cb47f9`, from this branch) already has these rpaths.

Failure scenario:
1. A user installs Hijack with brew or `install.sh`. The Mac has no Xcode.app (Command Line Tools only, the common case).
2. A process running as that user (an admin user, the default macOS account) creates
   `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx/Sparkle.framework/Versions/B/Sparkle`.
   `/Applications` is `drwxrwxr-x root admin`, so no password is needed.
3. At the next launch, dyld loads that file instead of `Contents/Frameworks/Sparkle.framework`.
4. The code runs inside Hijack, with its Accessibility grant and its key tap: a keylogger with no prompt.
   This also goes around macOS App Management protection, because nothing inside `Hijack.app` changes.

On this Mac `Xcode.app` is `root:wheel`, so this Mac is not exposed. A Mac without Xcode, or with a user-owned Xcode from a `.xip`, is.

Smallest fix:
- In `build.sh`, after the `cp` at `:26` and before `codesign`, delete every rpath except `/usr/lib/swift` and
  `@executable_path/../Frameworks` with `install_name_tool -delete_rpath`.
- Then assert the exact list (`otool -l ... | awk '/LC_RPATH/{getline;getline;print $2}'`) and fail the build on any other entry.
- Add that assertion to `scripts/mutate-build.sh` or CI, so a toolchain change cannot bring it back.
- Add the row to the threat model (S6).

#### M2. Merging `install.sh` to main breaks the README install command until a release carries `Hijack.zip.sha256`

- The README tells users to run `curl -fsSL https://raw.githubusercontent.com/zl190/hijack/main/install.sh | sh`. So a merge to main deploys `install.sh` at once.
- The latest release is `v1.1.4`. Its only asset is `Hijack.zip` (`gh release view`).
- `install.sh:16-20` stops when `Hijack.zip.sha256` is missing. `docs/threat-model.md:90` says so: releases before 1.2.0 are refused.
- The success path with a real `Hijack Signing` build was never run: case (a) of `scripts/test-install.sh` uses an ad-hoc build and `HIJACK_SKIP_AUTHORITY_CHECK` (`:52-71`).

Failure scenario: from the merge until 1.2.0 is public, every new user who follows the README gets
"checksum file missing from the release" and no app.

Smallest fix (either one):
- Before the merge, download the published `v1.1.4` `Hijack.zip` (`gh release download`, not a rebuild), write
  `Hijack.zip.sha256` from it, upload it to `v1.1.4`. Then run `install.sh` once against the real release with
  `HIJACK_INSTALL_DIR` set to a temp folder and no skip flag. That proves the self-signed authority passes
  `codesign --verify --strict --deep` and the `Authority=` match.
- Or hold the `install.sh` change off main until 1.2.0, with its `.sha256`, is public.

### Should-fix

#### S1. The MetricKit parser probably reads three fields from the wrong place or the wrong type (W3)

- `MetricsSummary.swift:70` reads `hangDuration` directly on each hang object. The comment at `:15-16` says the
  metadata key is `metaData`, not `diagnosticMetaData`.
- The OS MetricKit binary has a JSON key table. It contains `diagnosticMetaData`, followed by the crash and hang
  metadata keys (`exceptionType`, `exceptionCode`, `signal`, `terminationNamespace`, `hangDuration`) and then
  `timeStampBegin`, `timeStampEnd`, `hangDiagnostics`, `crashDiagnostics`. I found no `metaData` key next to them.
- Public `jsonRepresentation()` samples (Apple's simulated payloads, from memory, not checked here) write a
  `Measurement` as a string: `"cumulativeCPUTime" : "100 sec"`, `"peakMemoryUsage" : "200,000 kB"`,
  `"hangDuration" : "20 sec"`. `measurement()` at `:92-97` accepts only a number or a `{value, unit}` object.
  A string gives nil.
- The fixtures are hand-written in the parser's own shape (`{"value": 2.5, "unit": "s"}`, `metaData`, `iPhone OS`).
  So the tests prove the parser matches the fixtures, not MetricKit.
- No real payload exists on this Mac yet (`~/Library/Logs/Hijack-metrics` is absent). So this rests on the key
  table and the public samples, not a device payload.

Effect if the samples are right: `hijack stats` shows hang and crash counts and the last crash date (all correct),
but never a longest hang, CPU time or peak memory. The rows are absent, not zero; `--json` shows `"cpuSecondsByDay": {}`.
A separate risk: `:96` treats an unknown unit as the base unit, so `"KB"` would read as bytes, 1000 times too small,
and print as a fact (`testMeasurementKeepsTheRawValueForAnUnknownUnit` locks that in).

Smallest fix:
- Accept `"<number> <unit>"` strings (drop grouping commas). Read `diagnosticMetaData.hangDuration`, with the
  current place as a fallback.
- Return nil for an unknown unit.
- When the first real payload arrives, copy it (trimmed) into `Fixtures/metrickit/` and test against it.
  Until then, `docs/usage.md:48-52` should say the three fields are unverified.

#### S2. `doctor`'s "crash newer than the last start" compares against the last state write (W3)

- `Sources/App/CLI.swift:210` compares `lastCrashDate` with `state.json`'s `updated`.
- `updated` is written on every state write: the end of each dictation and each menu open
  (`Sources/App/AppState.swift:43`, `Sources/App/Menu.swift:87-91`). It is not the start time.
- `AppState.read()` returns nil when the recorded pid is dead (`Sources/App/AppState.swift:53`). So the rule cannot
  warn while Hijack is not running, the one case where a crash matters most.
- `lastCrashDate` is the payload's `timeStampEnd` (`MetricsSummary.swift:76`), the end of a reporting window,
  not the crash time.

Failure scenario: Hijack crashes at 09:00 and restarts at 09:01. The user dictates at 09:30 (`updated` = 09:30).
The payload arrives with `timeStampEnd` 09:05. `doctor` says nothing. Without the 09:30 dictation it warns.
The answer depends on when the user last dictated.

Smallest fix: write a `startedAt` field once at launch, and compare against it. Put the rule in Core as a pure
function, with a test for each side of the boundary. Or change the rule to "a crash in the last 24 hours", which
does not need a start time.

#### S3. `MetricsSummaryTests` fails in every time zone west of UTC

- `MetricsSummary.day(_:)` formats in the current time zone (`MetricsSummary.swift:120-123`).
- The fixtures stamp `2026-10-01T00:00:00.000+0000`. In `America/Los_Angeles` that is `2026-09-30`.
- My scratch probe printed `2026-10-01` (local, +11), `2026-09-30` (`TZ=America/Los_Angeles`), `2026-10-01` (`TZ=UTC`).
- So `testCPUTimeSumsPerDayAcrossMetricPayloads` (`:34-35`) and `testMixedFolderFoldsEveryFileTogether` (`:65-66`)
  go red for a contributor in the Americas. CI is UTC, so it stays green.

Smallest fix: stamp the fixtures at 12:00 UTC, or give `summarize` a `timeZone` parameter and pass UTC in the tests.

#### S4. `scripts/test-install.sh` launches the test build on the user's Mac (W4)

- `install.sh:64` runs `open "$INSTALL_DIR/Hijack.app"` for every `INSTALL_DIR`, not only `/Applications`.
- Case (a) installs into a temp folder, so the dev build starts from there.
- If the real Hijack runs, the copy finds the instance lock and exits (`Sources/App/main.swift:30-33`). No harm.
- If the real Hijack does not run, the copy takes the lock, writes the real `state.json`, and re-registers the
  relauncher LaunchAgent from the temp bundle (`Sources/App/Menu.swift:94-102`). An ad-hoc build is not trusted,
  so it also opens the settings window and the Accessibility prompt. The cleanup then deletes that bundle.

Smallest fix: run the `open` loop only when `INSTALL_DIR` is `/Applications`, like `pkill` and `ln`.

#### S5. No test case reaches the signing-authority check (W4)

- Cases (a), (b) and (d) set `HIJACK_SKIP_AUTHORITY_CHECK=1` (`scripts/test-install.sh:70`, `:91`, `:134`).
  Case (c) stops at the missing checksum first. `make build` is always ad-hoc, so case (a) always takes the skip branch.
- A mutant that changes `!=` to `=` at `install.sh:47` keeps all four cases green (by reading, not run).

Smallest fix: add case (e): a good zip and a good checksum, no skip flag, the default expected authority.
Assert exit 1, "Signing authority mismatch", and no app in the install folder.

#### S6. The threat model's cites are stale, and three rows are wrong (W2)

Stale after W1 and W5:
- Every app file is cited as `Sources/X.swift`. They moved to `Sources/App/X.swift` (System, Config, CLI, AppState,
  Shared, Menu, Providers).
- Lines now point at other code: `Sources/CLI.swift:293` (row 6) is the `talk-key` parser; the log line is
  `Sources/App/CLI.swift:319`. `build.sh:85` and `:46` (§2) are past the end and an `iconutil` line; the file has
  82 lines, `SUFeedURL` is `:72`, `SUPublicEDKey` is `:33`. `System.swift:118-121` (rows 7, §1) is now `:134-136`.
  `Engine.swift:438-459` (row 10) starts in `stopForQuit`; `reenableTap` starts at `:452`.

Wrong:
- Row 2 says GAP for "a second process writes its own state.json". The flock instance lock exists
  (`Sources/App/main.swift:19-41`, commit 1807357, after the audit). The open part is narrower: a mistyped command
  starts the app when no instance runs.
- Row 12 says CONTROL. The checksum comes from the same release as the zip, so it stops a corrupt or swapped
  single file, not an attacker who can write release assets. The authority check compares a certificate common
  name. Anyone can make a self-signed certificate named "Hijack Signing".
- No row for M1, and §1 does not list `~/Library/Logs/Hijack-metrics` (crash and hang reports) as an asset.
  §5 does not list the new `system` block in `hijack stats --json`.

Smallest fix: regenerate every cite against this branch. Restate row 12 as "detects corruption and a single swapped
asset; does not stop a compromised release". Optional: pin the certificate, not the name:
`codesign --verify --strict --deep -R='certificate leaf = H"<sha1 of Hijack Signing>"'`. Add rows for M1 and the
MetricKit folder.

#### S7. ADR 0021 dismisses `disable-library-validation` for a wrong reason (W6)

- `docs/adr/0021-...md:38-39` says the entitlement turns the check off, "so the runtime no longer protects against
  the main threat".
- The hardened runtime controls `DYLD_*` variables with a separate entitlement
  (`com.apple.security.cs.allow-dyld-environment-variables`). With only `disable-library-validation`, the runtime
  still ignores `DYLD_INSERT_LIBRARIES`, which is the exact threat in row 11.
- The entitlement does not stop M1 (a planted library on an rpath still loads). So M1 needs its own fix either way.

Smallest fix: repeat the W6 live test with `--options runtime` and an entitlements file that holds only
`com.apple.security.cs.disable-library-validation`. If the app starts, ship it and close row 11 as a control.
If not, record the new evidence in the ADR.

#### S8. Two property invariants are weaker than the doc allows (W2)

- `PropertyTests.swift:87-95`: a `finish` closes an open `sendTalkKey`. In the machine, every exit from `listening`
  emits `releaseTalkKey` (`SessionMachine.swift:62`, `:82`). So a stronger statement is true: the talk key's send and
  release strictly alternate, and the key is up at every `begin` and every `finish`.
- `:79-85`: the release flag starts false, so a `releaseTalkKey` before any send passes once.
- Surviving mutant (by reading, not run): in `stop()`, drop `releaseTalkKey` when `mode.toggle && !mode.switchesInput`.
  A toggle-mode app session then leaves the talk key down. `finish` closes the send, and invariant 4 checks hold mode
  only, so the property test stays green. `SessionMachineTests.swift:55` catches it, so this is not a shipped hole.
- `:70-75` checks only half of doc line 12. "Elsewhere quit changes nothing" is also true and cheap: `after == before`.

Smallest fix: track one `talkKeyDown` Bool. `sendTalkKey` requires false; `releaseTalkKey` requires true; `begin` and
`finish` require false. Add the `after == before` half for `quit`. Add the mutant above to
`scripts/mutate-check-property-tests.sh`.

### Nit

- N1. Five comments cite `KeysTests.testW5_QuickKeysAlwaysResolveToANamedKey`. The class is `FI4KeysTests`
  (`Sources/Core/Keys.swift:128`, `Sources/App/Config.swift:132`, `Sources/App/Settings.swift:409`, `Sources/App/Menu.swift:279`, `:306`).
- N2. At a rate of 0.9896, `hijack stats` prints `this period 99.0%  not met`, and `--json` prints `successRate 0.99`
  with `met false` (`Sources/App/CLI.swift:370`, `:403`). Print the rate rounded down, or with two decimals.
- N3. Engine keeps its state as `public var` (`machine`, `generation`, `quitting`, `span`, ...;
  `Sources/Core/Engine.swift:66-84`). The app reads `tapInstalled` and `machine.isActive` and sets `paused`.
  The tests use `@testable`. Make the rest `public private(set)` or internal, or use `package` (tools 5.9).
- N4. The Sparkle version lives in `Package.swift:7` and `scripts/fetch-sparkle.sh:8`. A mismatch fails loudly, so
  this is safe. A bare `swift test` on a fresh clone fails; say "run `make test`" in the README build line.
- N5. `Metrics.swift`: metric and diagnostic files share one cap of 30, so a burst of hang reports can push out
  the daily metric files. Two deliveries of one kind in the same second overwrite each other (`:31`).
  `trim()` also deletes non-JSON files in the folder.
- N6. `docs/usage.md:48` says macOS sends a report about once a day. MetricKit delivery depends on the user's
  analytics sharing setting (verify on macOS). Say "if analytics sharing is on".
- N7. `HIJACK_SKIP_AUTHORITY_CHECK=0` also skips: the test is "non-empty" (`install.sh:45`). Test for `1`.
- N8. If the nil-context path ever ran, it would log once per key event (`Sources/App/System.swift:124`). Acceptable
  for a path that cannot happen; a once-only flag would bound it.
- N9. `build.sh` no longer pins the architecture. The old call had `-target arm64-apple-macos13`. A build in a
  Rosetta shell gives an x86_64 binary that then runs translated, key tap included. Add
  `--triple arm64-apple-macosx13.0`, or check `lipo -archs` before signing.
- N10. `scripts/test-install.sh` and `scripts/mutate-build.sh` are not in CI. Both can run on the macOS runner.

---

## 3. New tests: do they fail on revert?

| Test | Mutation or revert | Red? |
|---|---|---|
| `StatsTests.testMetAtExactly99Percent` | `>=` to `>` in `met` (`Stats.swift:105`) | Yes, `XCTAssertEqual(s.met, true)` (by reading) |
| `StatsTests.testNotMetAt98Point9Percent` | `met` always true | Yes, `XCTAssertEqual(s.met, false)` (by reading) |
| `StatsTests.testMetIsNilWhenNothingWasJudgedYet` | `met` returns false when the rate is nil | Yes, `XCTAssertNil(s.met)` (by reading) |
| `PropertyTests` | 4 mutants in `scripts/mutate-check-property-tests.sh` | Committed script; I did not re-run it. One gap: S8 |
| `MetricsSummaryTests` hang max, crash count | 2 mutants in `scripts/mutate-check-w3-metrics.sh` | Committed script; I did not re-run it |
| `MetricsSummaryTests` other cases | each pins one branch edge | Not vacuous. But all check the parser against its own invented shape (S1), and two depend on the time zone (S3) |
| `FI4KeysTests.testW5_QuickKeysAlwaysResolveToANamedKey` | remove `fn` from `namedKeys` | Yes, `XCTAssertNotNil(KeySpec.named(id), id)`. It guards the table; it does not test a W5 code change, and does not need to |
| `scripts/test-install.sh` (b), (c), (d) | drop the sum compare / the missing-file check / `codesign --verify` | Yes, each asserts the message and an empty install folder |
| `scripts/test-install.sh` authority | `!=` to `=` at `install.sh:47` | **No** (S5) |
| `scripts/mutate-build.sh` | wrong target path; no `-F` | Yes. It does not check the rpath list (M1) |

No test is vacuous. W5 has no runtime test for the tap guard; the guard is on a path that cannot be reached from a
test, and the exhaustive switch is checked by the compiler.

---

## 4. Verdict

**Merge after fixes.** Fix M1 in `build.sh` before merge, and rebuild the installed app. Do M2 before merge: it is an
order-of-operations fix (upload a checksum to v1.1.4 and run the real install once, or hold `install.sh`).
Fix S1-S5 before `make release` of 1.2.0: S1 and S2 decide whether the W3 output is true, S3-S5 are test gaps.
S6-S8 and the nits can follow in the next wave.
