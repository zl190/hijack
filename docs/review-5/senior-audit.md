# Senior audit: what the checklist does not cover

## Scope and method

- Branch `main` at `0cb688b`. Read-only audit. The only file written is this one.
- I read `README.md`, `docs/usage.md`, `docs/state-machine.md`, `docs/fmea.md`, `docs/review-4/*.md`, `docs/distribution-spec.md`, all of `Sources/` and `Sources/Core/`, the tests, `build.sh`, `Package.swift`, the install scripts and the LaunchAgent plist.
- I excluded every item on the owner's checklist. That list is done or queued.
- `swift test`: 92 tests, 0 failures, 1.6 s. The 4 `WatchTests` take 1.5 s of that. No compiler warnings.
- `./build.sh`: builds `build/Hijack.app` 1.1.4, arm64, ad-hoc signature, no warnings. `codesign -dv` shows `flags=0x2(adhoc)`: no hardened runtime.
- Extra check: `swiftc -typecheck -strict-concurrency=complete` gives 39 unique warnings. `-swift-version 6` fails with errors.
- Line numbers refer to `0cb688b`.

## Ranked findings

| Rank | Item | Why it matters | Evidence | Size | Ticket |
|---|---|---|---|---|---|
| 1 | A bare or mistyped `hijack` starts a second app; no single-instance guard | Two taps, two menu icons, `state.json` flips between PIDs | `main.swift:13`, `CLI.swift:13`, `install.sh:16` | S | `single-instance-and-cli-typo` |
| 2 | Quit, SIGTERM, logout or an update during a dictation leave the talk key down and the voice IME selected | FM-10 covers crashes only; graceful exits are cheap to clean up and are the common case | `Menu.swift:8-80` (no `applicationWillTerminate`), `install.sh:8`, `install-from-source.sh:6`, `Engine.swift:54` | S | `clean-up-on-terminate` |
| 3 | Settings are re-read from disk inside the tap callback | Two file reads and a JSON parse per Handy dictation and per passthrough release; feeds FM-26 slow key events | `Engine.swift:175`, `Engine.swift:81-85`, `Config.swift:115-122`, `Providers.swift:121` | S | `refresh-plan-off-the-tap` |
| 4 | FMEA claims unit tests for FM-19, FM-21, FM-22 that do not exist | The parsers of other apps' files (WeType MMKV, Handy binding) and the config have no test | `docs/fmea.md:100-103`, `Providers.swift:14-41`, `Keys.swift:75-96`, `Config.swift:35-66` | M | `test-third-party-parsers` |
| 5 | No hardened runtime on an app that holds Accessibility and a keyboard tap | `DYLD_INSERT_LIBRARIES` can load code into a trusted process: a keylogger with the user's own grant | `build.sh:42`, codesign flags `0x2` | S | `hardened-runtime` |
| 6 | The signing key and the Sparkle EdDSA key live only in one login keychain | Loss of that Mac ends updates and forces every user to grant Accessibility again | `distribution-spec.md:20`, `distribution-spec.md:87`, ADR 0007 | S | `key-escrow-and-restore-drill` |
| 7 | An ad-hoc install over a signed install leaves a stale "on" Accessibility entry | The UI says "Allow…", but the switch in System Settings is already on; users toggle it and nothing changes | `install-from-source.sh:5`, `build.sh:42`, `Menu.swift:171-172`, `Settings.swift:302-305` | S | `stale-grant-guidance` |
| 8 | Key recording pauses the engine with no timeout and no fault line | Switch apps while recording, and every dictation is dead with no signal | `Settings.swift:101`, `Settings.swift:139`, `Settings.swift:500`, `Engine.swift:415`, `MenuState.swift:33-38` | S | `bound-the-recording-pause` |
| 9 | Builds have no identity and no symbols | A local build and the release both say 1.1.4; crash reports have no line numbers; releases can come from a dirty tree | `build.sh:10`, `build.sh:36-37`, `release.sh:7` | S | `build-identity-and-dsym` |
| 10 | No bug-report bundle | Users must collect logs by hand; the log holds the front app of every dictation | `usage.md:51`, `Engine.swift:322`, `Focus.swift:5` | M | `doctor-report` |
| 11 | "Everything on main" is a convention, not a compiler check | 39 strict-concurrency warnings; Swift 6 mode fails; a future off-main call compiles silently | `Seams.swift:9`, `Shared.swift:45`, `System.swift:135-138`, `Menu.swift:30-57` | M | `main-actor-isolation` |
| 12 | The live layer has no smoke test | Marker round-trip, combo modifier order, CoreAudio and window-list calls run only by hand | `System.swift:30-81`, `System.swift:167-192` | M | `hijack-selftest` |
| 13 | Settings controls have empty accessibility labels | VoiceOver reads "switch, off" with no name for every toggle, picker and stepper | `Settings.swift:281`, `:376`, `:405`, `:411`, `:415`, `:418`, `:435` | S | `settings-a11y-labels` |
| 14 | The config writer does not escape strings; loads do not range-check numbers | `hijack set source 'a"b'` writes invalid JSON and blocks all saves; a hand edit can set a 10-minute restore wait | `Config.swift:76`, `CLI.swift:220-223`, `Config.swift:61-63` | S | `config-escape-and-validate` |
| 15 | `install.sh` installs and de-quarantines a download it does not verify | A swapped release asset runs with no check | `install.sh:6-11` | S | `verify-download-identity` |
| 16 | Login-item and relauncher errors are swallowed | `.requiresApproval` shows as "off" with no reason; re-register runs on every launch | `Settings.swift:406`, `Menu.swift:64-67`, `Menu.swift:294-295` | S | `surface-smappservice-status` |
| 17 | The summary line carries localized names | Stats split one tool into two after a language change; the parser depends on display text | `Engine.swift:307`, `Engine.swift:310`, `Keys.swift:50`, `Stats.swift:47`, `Stats.swift:116` | S | `log-ids-not-names` |
| 18 | Settings window tabs and title keep the launch language | Language change updates the cards but not the toolbar | `Settings.swift:466-467`, `Settings.swift:486-493` | S | `relocalize-settings-chrome` |
| 19 | Dead code | Four `@objc` actions and one free function have no caller | `Menu.swift:273-296`, `InputSource.swift:31-37` | S | `remove-dead-actions` |
| 20 | No CI guards beyond tests | Zero warnings today, but nothing keeps it so; no coverage number; toolchain not pinned | `Package.swift:6-13`, `build.sh:10` | S | `ci-guards` |
| 21 | FSEvents tests use real time | Low flake risk on a loaded runner; the inverted test cannot prove absence | `WatchTests.swift:26`, `WatchTests.swift:54` | S | `watch-test-timeouts` |

## Top ten in detail

### 1. Single instance and the CLI typo

`runCLI` returns nil for an empty or unknown first argument (`CLI.swift:13`). Then `main.swift:13-19` starts the full app. A user who types `hijack` or `hijack stauts` in a terminal starts a second Hijack. The terminal is the responsible process for TCC. If the terminal has Accessibility, the second copy installs a second head-insert tap. Two copies write `state.json` with different PIDs (`AppState.swift:42`). `open build/Hijack.app` next to `/Applications/Hijack.app` gives the same result, because LaunchServices allows two bundle paths. Smallest fix: print help and exit 2 for an unknown command. Start the app with no arguments only when `isatty(0)` is false, or require `--app`. At launch, exit when `NSRunningApplication.runningApplications(withBundleIdentifier:)` lists another PID.

### 2. Clean up on terminate

The delegate has no `applicationWillTerminate` (`Menu.swift:8-80`). The install scripts send SIGTERM with `pkill -x Hijack` (`install.sh:8`, `install-from-source.sh:6`). SIGTERM kills the process with no AppKit callback. A Sparkle update, Quit in toggle mode, and logout all end the process the same way. If a dictation is in `listening`, the posted talk key stays down. If it is in `waitingForText`, the user stays in the voice IME, because `previous` exists only in memory (`Engine.swift:54`). FM-10 (`fmea.md:91`) covers a crash, which no code can catch. A graceful exit can clean up. Smallest fix: add `Engine.shutdown()`. It posts the talk-key release when `machine.isActive`, and it selects `previous` when the current source is the voice IME. Call it from `applicationWillTerminate`. Add a `DispatchSource.makeSignalSource(signal: SIGTERM)` that calls `NSApp.terminate`. Add one FI test with the fakes.

### 3. Settings re-read inside the tap

`run` ends with `defer { if machine.state == .idle { refresh() } }` (`Engine.swift:175`). `refresh` calls `makePlan` (`Engine.swift:84`). `Plan(Model)` reads `forwardKey` and `voiceStyle` (`System.swift:11-14`). Each one calls `provider.detected()` (`Config.swift:115`, `Config.swift:121`). For Handy that is `Data(contentsOf:)` plus a JSON parse (`Providers.swift:121-122`), twice. For WeType it reads the MMKV file (`Providers.swift:16`). An app tool reaches `idle` inside the key event on every release (`SessionMachine.swift:62-63`). A passthrough release does the same (`SessionMachine.swift:68`). Review-4 M2 moved the `state.json` write off the tap; this read stayed. FM-26 already counts 10 slow key events in 20 dictations (`fmea.md:107`). Smallest fix: `clock.after(0) { [self] in refresh() }` in the `defer`. The guard in `refresh` already handles a press that comes first.

### 4. FMEA test claims and third-party parsers

The FMEA test column says "covered (Config)" for FM-19, "unit (Providers)" for FM-21 and "unit (log)" for FM-22 (`fmea.md:100-103`). No test calls `Config`, `weTypeVoice`, `handyVoiceKey` or the log writer. These files are in the app target, which `swift test` does not build (`Package.swift:10`). `weTypeVoice` parses a private binary format that another vendor can change (`Providers.swift:14-41`). `KeySpec(binding:)` and `KeySpec(json:)` are in Core, but no test calls them (`Keys.swift:58-96`). FM-21 is the only failure mode where a vendor update breaks Hijack with no code change on our side. Smallest fix: split `weTypeVoice(data: Data)` and `handyVoiceKey(data: Data)` into Core as pure functions. Commit two real fixture files. Test the binding grammar table. Correct the FMEA column until the tests exist.

### 5. Hardened runtime

`build.sh:42` signs with no `--options runtime`. The built bundle shows `flags=0x2(adhoc)` and no runtime flag. Without the hardened runtime, dyld honours `DYLD_INSERT_LIBRARIES`. A local process can run `open --env DYLD_INSERT_LIBRARIES=…` on Hijack. The injected code then runs inside a process that holds the Accessibility grant and a HID-level key tap. Smallest fix: sign with `--options runtime`. A self-signed identity has no Team ID, so library validation will reject the re-signed Sparkle framework. Add the entitlement `com.apple.security.cs.disable-library-validation` for that. Do not add `allow-dyld-environment-variables`. Verify on the T3 build: the app starts, the tap works, and an injected test dylib does not load.

### 6. Key escrow

D1 keeps the self-signed private key and the Sparkle EdDSA key in the owner's login keychain only (`distribution-spec.md:20`, `:87`). The certificate is valid until 2046, so expiry is not the risk. Loss of the keychain is the risk. A new certificate changes the designated requirement, so every user loses the Accessibility grant (ADR 0007). A new EdDSA key plus a new certificate in one release makes Sparkle refuse the update. Smallest fix: export both keys to an encrypted offline backup. Write a one-page restore drill. Run it once on a second user account.

### 7. Stale Accessibility entry after an ad-hoc install

`install-from-source.sh:5` runs `build.sh` with no `HIJACK_SIGN_ID`, so the build is ad-hoc (`build.sh:42`). It replaces a signed install. The TCC entry still shows Hijack with its switch on. `AXIsProcessTrusted()` returns false, so the menu says "Needs Accessibility permission — Allow…" (`Menu.swift:171-172`). The user finds the switch already on. Toggling it does not help; only removing the entry does. Smallest fix: when untrusted and the entry likely exists, show "Remove Hijack with −, then add it again". Offer a button that runs `tccutil reset Accessibility com.zl190.hijack`. Make `make install` use the signing identity when the keychain has it.

### 8. Bounded recording pause

`startRecording` sets `engine.paused = true` (`Settings.swift:101`). Only Esc, a recorded key, or closing the window clear it (`Settings.swift:107`, `:139`, `:500`). The monitor is a local monitor, so it sees no key while another app is in front. A user who clicks "Other Key…" and then switches app leaves `paused` true. `handle` then lets every key through (`Engine.swift:415`). The menu fault list has no entry for this (`MenuState.swift:33-38`). Smallest fix: stop recording on `windowDidResignKey`. Add a 30 s timeout. Add a `paused` case to `MenuFaults.firstLine` with a test.

### 9. Build identity and symbols

`CFBundleVersion` is the marketing version (`build.sh:36-37`). An ad-hoc local build and the signed release both report 1.1.4. `hijack version` prints only that string (`CLI.swift:24`, `CLI.swift:38`). `swiftc -O` runs without `-g` (`build.sh:10`), and no dSYM is kept. A crash report from a user then has no file or line. `release.sh:7` builds from the working tree with no clean-tree check. Smallest fix: set `CFBundleVersion` to `git describe --always --dirty`. Build with `-g`, run `dsymutil`, and keep the dSYM per release outside the zip. Make `make release` refuse a dirty tree.

### 10. Bug-report bundle

The issue path asks users to send version, macOS, tool and steps, and to "review logs before sharing" (`usage.md:51`). Each summary line ends with the front app's bundle ID (`Engine.swift:322`, `Focus.swift:5`). That is a timeline of where the user dictated. Smallest fix: `hijack doctor --report` writes one text file. It holds `doctor` output, the `--json` output of `status`, `sources` and `stats`, `sw_vers` and the build ID from item 9. It adds the last 200 log lines, with each `front=` value replaced by a hash. It lists any `Hijack*` file in `~/Library/Logs/DiagnosticReports`. It prints the path and sends nothing.

## Not worth doing

- **Retain callbacks for the tap and FSEvents contexts.** Both use `passUnretained` (`System.swift:97`, `Watch.swift:25`). `AppDelegate` owns both objects for the process lifetime (`Menu.swift:9`, `Menu.swift:23`), and `SettingsWatch.deinit` stops the stream first (`Watch.swift:44-46`).
- **Removing force unwraps on the hot path.** `micOffSince!` sits inside a branch that checked it (`Engine.swift:291-292`). The modifier table is exhaustive (`System.swift:52`). FSEvents always passes `info` (`Watch.swift:28`).
- **Sendable work on `offMain`.** The closure sends only `[pid_t]`, a `Bool` and a stateless struct (`Engine.swift:277`, `System.swift:125-130`). Item 11 covers the compiler check; no data race exists today.
- **A string catalog for localization.** About 108 `L(zh, en)` calls in two files (`Menu.swift`, `Settings.swift`) are fine for two languages. Revisit when a third language is requested.
- **A universal binary.** `install.sh:4` and `README.md:15` state Apple silicon. Keep it, and make the cask declare `depends_on arch: :arm64`.
- **swiftlint or swift-format.** The dense one-line style is consistent. A formatter pass would rewrite every file and break line-by-line review diffs such as `docs/review-4/di-review.md:26`.
- **Dependency pinning beyond Sparkle.** The package has no dependencies (`Package.swift:9-12`). The spec already pins Sparkle by sha256 (`distribution-spec.md:25`).
- **Menu-bar icon appearance work.** Both icons are templates with an accessibility description (`Menu.swift:128-130`).
- **Log file permissions.** The log is 0644 (`Shared.swift:59`), but `~/Library` is 0700, so other users cannot reach it.
- **Restarting after a crash.** ADR 0012 rejects it on purpose. The stuck-key check at start (`Engine.swift:359-366`) covers the next launch.
- **`AppState.read` PID reuse.** `kill(pid, 0)` can match a reused PID (`AppState.swift:52`). The window is one crash plus one PID collision; `doctor` is a diagnostic, not a gate.
