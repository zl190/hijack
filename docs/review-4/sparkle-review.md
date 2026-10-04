# Independent review: Sparkle 2.10.0 in-app updates (T3)

Scope: branch `dist-sparkle`, `git diff dist-makefile-ci..HEAD`, 6 commits (bc690d5 to 2bf8ef1), 13 files, +232/-8.
I also read the whole `Makefile`, including the T1 part from another builder.
Spec: `docs/distribution-spec.md` §2 D1-D8, §3 T1 and T3, §5.

Method:
- I read every changed file, `Sources/main.swift`, `install.sh` and `Package.swift`.
- I read the Sparkle 2.10.0 source at the tag (links below use `S/` = `https://github.com/sparkle-project/Sparkle/blob/2.10.0/`).
- I inspected the existing `build/Hijack.app` with `codesign -dvv`, `codesign --verify --deep --strict` and `otool`.
- I ran `tar -x` with the `build.sh` member list into a scratch folder. It extracts only `Sparkle.framework` and `bin`.
- I ran the built binary in CLI mode only (`hijack version` through a symlink in a scratch folder). I did not launch the app.
- I ran 7 mutations of `Sources/Core/UpdateNotice.swift` in a scratch copy of the package (§3).
- I did not edit source, install, push, tag or run `make release`. The lead's facts (100 tests, `./build.sh`, `otool -L`, 6.4 MB) stand.

---

## 1. Questions from the brief, short answers

| # | Question | Answer | Evidence |
|---|---|---|---|
| 1a | curl flags | `-fsSL -o` is correct for a fail-on-HTTP-error download. The file goes straight to its final name, so a partial file survives (S1). | `build.sh:18-19` |
| 1b | sha256 pin | Checked only on download. After that, anything in `.sparkle/` is trusted (S1). | `build.sh:16-21` |
| 1c | Atomic extract | No. A stopped `tar` leaves `.sparkle/Sparkle.framework`, and the next build skips the extract (S1). | `build.sh:16`, `:21` |
| 1d | Stale `.sparkle/` from an older Sparkle | Reused without a check. A bump of `SPARKLE_VERSION` builds with the old framework (S1). | `build.sh:16` tests a folder, not a version |
| 1e | swiftc flags | Correct. `otool -l` shows `LC_RPATH @executable_path/../Frameworks`. A CLI call through a symlink loads the framework (dyld resolves the real path). | `build.sh:23-25`; scratch run printed `1.1.4`, exit 0 |
| 1f | XPC services removed | Allowed for apps that are not sandboxed. Sparkle checks an XPC service only when its `SUEnable…Service` key is set, and Hijack sets none. | https://sparkle-project.org/documentation/sandboxing/ ("you may choose to remove these services"); `S/Sparkle/SPUUpdater.m#L235-L251` |
| 1g | Signing order | Framework, then app: correct (inside out). | `build.sh:68-69` |
| 1h | Same identity on `Autoupdate` and `Updater.app`? | No. `codesign` without `--deep` does not re-sign nested code. Both keep Sparkle's own ad-hoc signature. Sparkle does not need the same identity there (N1). | `codesign -dvv`: `Autoupdate` and `Updater.app` show `Signature=adhoc` while the framework is re-signed; `S/Autoupdate/SUCodeSigningVerifier.m#L73-L77` (no nested-code flag in the match), `#L445-L451` (no team ID, no requirement) |
| 1i | Ad-hoc dev path | Works. `--verify --deep --strict` passes on the current ad-hoc build. But the placeholder key breaks the updater at launch (M1). | `codesign --verify` output: "valid on disk", "satisfies its Designated Requirement" |
| 2a | Can a placeholder build reach a user? | Not through `make release` (`Makefile:63-65`). Yes through `make install`, the documented source path (D5). | `assets/sparkle-public-key.txt:1`, `build.sh:30-31` only warns |
| 2b | Crash or log on a bad `SUPublicEDKey`? | No crash. Sparkle logs, refuses to start the updater, and shows a modal alert 1 s after every launch (M1). | §2 M1 |
| 3a | Controller lifetime | Good. A `let` on `AppDelegate`; the delegate is a global in `main.swift:16`. | `Sources/Menu.swift:16` |
| 3b | `startingUpdater: true` cost | Small. `startUpdater` runs on the main thread before the tap starts. It reads Info.plist keys and decodes the key. It does no network and no file write. The update cycle starts one run-loop turn later. | `S/Sparkle/SPUUpdater.m#L146-L191` |
| 3c | Toggle bindings | Correct. They write `SPUUpdater` properties; Sparkle stores them. They read the value on appear only. | `Sources/Settings.swift:401-418` |
| 3d | "Check Now" while a check runs | Harmless. Sparkle brings the open window to the front, or logs and returns. The button is not disabled (N5). | `S/Sparkle/SPUUpdater.m#L698-L716` |
| 3e | `LSUIElement` and Sparkle windows | Sparkle shows scheduled alerts behind other apps unless it is near launch, and logs a warning (S5). | `S/Sparkle/SPUStandardUserDriver.m#L161-L170`, `#L268-L285` |
| 4a | `persistentDomain(forName:)` via symlink | The read works. But Sparkle never writes `SULatestAppcastItemFound` to user defaults (M2). | §2 M2 |
| 4b | `<VERSION>.<git sha>` as `CFBundleVersion` | Unsafe for builds with the same `VERSION` (S6). | §2 S6 |
| 5a | Re-run after a failure | Safe before `gh release edit --draft=false`. After it, the draft check stops the re-run and the cask is not bumped (S4). | `Makefile:48-59`, `:81-89` |
| 5b | `edSignature` grep guard | Matches any item, not the new one (S3). | `Makefile:76-78` |
| 5c | sed on the enclosure URL | Changes only the `url` value. `length`, `type`, `sparkle:edSignature` and the `<sparkle:version>` element survive. | `Makefile:79`; `S/generate_appcast/FeedXML.swift#L590-L603` |
| 5d | Old zips in `dist/` | Re-signed and re-listed on every run, with a wrong URL (S2). | §2 S2 |
| 5e | Uploaded zip = signed zip | Yes. `cp` at `:73` makes the signed copy. Nothing writes `$(ZIP)` between `:73`, the upload at `:80` and the cask sha at `:82`. | `Makefile:67-82` |
| 5f | Tag, draft and identity checks | Correct and before the build. The tree is not checked for local changes (N3). | `Makefile:45-65` |
| 6 | Each new Core test fails on revert | Yes for 7 of 8 tests (§3). | §3 |

---

## 2. Findings

### Must-fix

#### M1. Every build from the repo shows "Unable to Check For Updates" 1 s after each launch
- `assets/sparkle-public-key.txt:1` is `REPLACE-WITH-generate_keys-OUTPUT`. `build.sh:30` writes it into `SUPublicEDKey` (`build.sh:62`).
- Sparkle decodes the key as base64 with no options (`S/Sparkle/SUSignatures.m#L34-L46`). The placeholder has `-` and `_`, so the decode returns nil. I confirmed this with `Data(base64Encoded:)`.
- The key status becomes invalid (`S/Sparkle/SUSignatures.m#L160-L175`). `startUpdater` then fails with "The EdDSA public key is not valid" (`S/Sparkle/SPUUpdater.m#L332-L338`).
- `SPUStandardUpdaterController` shows a modal `NSAlert` 1 s later (`S/Sparkle/SPUStandardUpdaterController.m#L78-L100`).

Failure scenario:
1. A user follows the source path, `make install` (D5).
2. Hijack starts. One second later a modal alert says "Unable to Check For Updates".
3. This repeats on every launch, and on every relaunch by the relauncher LaunchAgent.
4. "Check for Updates…" stays disabled, because `canCheckForUpdates` is false (`S/Sparkle/SPUStandardUpdaterController.m#L109-L115`).

The key tap keeps working during the alert, because its source is in `.commonModes` (`Sources/System.swift:120`).
The release path is guarded (`Makefile:63-65`), so signed releases are not affected.

Smallest fix (both parts):
- Before merge, the owner runs `generate_keys` (T3 step 7) and commits the real public key.
- In `build.sh`, omit `SUPublicEDKey` when the file is a placeholder. In `Menu.swift:16`, pass `startingUpdater: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil`. A fork or CI build then has no updater and no alert.

#### M2. `hijack version` never prints an update: Sparkle does not store `SULatestAppcastItemFound` in user defaults
- `Sources/CLI.swift:45` reads `SULatestAppcastItemFound` from the app's defaults domain.
- In Sparkle, `SULatestAppcastItemFound` is the value of `SPULatestAppcastItemFoundKey` (`S/Sparkle/SUConstants.m#L56`). It is a key in the `userInfo` of the "no update found" `NSError` (`S/Sparkle/SPUBasicUpdateDriver.m#L253-L254`; `S/Sparkle/SPUUpdaterDelegate.h#L185-L186`). Its value is an `SUAppcastItem` object, not a dictionary.
- Sparkle writes these defaults only: `SUHasLaunchedBefore`, `SULastCheckTime`, `SUFeedURL`, `SULastProfileSubmissionDate`, `SUEnableAutomaticChecks`, `SUScheduledCheckInterval`, `SUAutomaticallyUpdate`, `SUSendProfileInfo` and the three skip keys (grep of `forUserDefaultsKey` in `S/Sparkle/`).

Failure scenario:
1. Hijack 1.2.0 finds 1.2.1 at its daily check. The user closes the alert.
2. The user runs `hijack version`. It prints `1.2.0` and nothing else.
3. T3 item 4 is not met. `release-notes/v1.2.0.md:4` and `docs/usage.md:41` promise a feature that does not work.

The 8 tests pass because they test `UpdateNotice` with hand-made input. No test covers the input source.

A second defect is on the same path. `SUSkippedVersion` holds the item's `versionString`, that is `sparkle:version` (`S/Sparkle/SPUSkippedUpdate.m#L56-L68`). The CLI compares it with `displayVersionString` (`Sources/CLI.swift:46-47`). The two are equal today only because `CFBundleVersion` equals `CFBundleShortVersionString` (`build.sh:57-58`).

Smallest fix:
- Give the controller an `SPUUpdaterDelegate` (`Menu.swift:16`, `updaterDelegate: nil` today).
- In `updater(_:didFindValidUpdate:)`, write `HijackUpdateFound = item.displayVersionString` and `HijackUpdateFoundBuild = item.versionString` to `UserDefaults.standard`.
- In `updaterDidNotFindUpdate(_:)`, remove both keys.
- In the CLI, read these keys. Compare `SUSkippedVersion` with `HijackUpdateFoundBuild`.
- Or remove the feature and the two doc lines for 1.2.0.

#### M3. The release notes become a link to a file that is never uploaded
- `Makefile:74` copies the notes as `dist/Hijack-$(VERSION).md`. `Makefile:75` runs `generate_appcast` without `--embed-release-notes`.
- `generate_appcast` embeds a notes file only when it is an HTML fragment, or when the flag is set (`S/generate_appcast/ArchiveItem.swift#L447-L480`). A `.md` file gets a `<sparkle:releaseNotesLink>` instead (`S/generate_appcast/FeedXML.swift#L527-L541`).
- With no `--release-notes-url-prefix`, the link is relative to `SUFeedURL` from the app's Info.plist (`S/generate_appcast/ArchiveItem.swift#L238`, `#L498-L508`). The result is `https://github.com/zl190/hijack/releases/latest/download/Hijack-1.2.0.md`.
- `Makefile:80` uploads only `Hijack.zip` and `appcast.xml`.

Failure scenario:
1. A 1.2.0 user gets the 1.2.1 alert.
2. The release-notes pane loads the link and gets HTTP 404.
3. The user sees an error in place of the notes. T3 acceptance 2 ("shall show the update with the release notes") fails.

Smallest fix: add `--embed-release-notes` at `Makefile:75`. Sparkle 2.9+ renders an embedded `<description sparkle:format="markdown">` (https://sparkle-project.org/documentation/publishing/). Update T3 item 5 in the spec: it still names `.html` and `pandoc`.

### Should-fix

#### S1. The Sparkle cache in `.sparkle/` is not atomic and not tied to a version
- `build.sh:18`: `curl -o` writes to the final name. A dropped connection leaves a partial `.tar.xz`. `set -e` stops the build, but the next build sees the file (`[ -f ]`), skips the download, and fails the sha check forever. The message does not say to delete the file.
- `build.sh:16`: the test is "folder `Sparkle.framework` exists". A `tar` stopped after the framework and before `bin/` leaves no `bin/`. `make release` then fails at `.sparkle/bin/generate_appcast` (`Makefile:75`).
- `build.sh:16`: a later bump of `SPARKLE_VERSION` keeps the old `.sparkle/Sparkle.framework`. The pin is never checked again, and the build embeds the old version without a message.

Smallest fix: use `SPARKLE_DIR=.sparkle/$SPARKLE_VERSION`. Download to `$SPARKLE_TAR.part`, check the sha, then `mv`. Delete the file when the sha fails. Extract to a temporary folder in `.sparkle/`, then `mv` it to `$SPARKLE_DIR`. Point `SPARKLE_BIN` in `Makefile:14` at the same folder.

#### S2. Old zips in `dist/` get the URL of the new release
- `generate_appcast` rewrites the enclosure of every item that has a zip in the folder (`S/generate_appcast/FeedXML.swift#L325-L378`, `#L581-L603`). The URL is `--download-url-prefix` plus the file name.
- `Makefile:15`: the prefix is `…/download/v$(VERSION)/`. `Makefile:79` fixes only the new item.

Failure scenario: at 1.2.1, the 1.2.0 item points to `…/download/v1.2.1/Hijack-1.2.0.zip`. That asset does not exist. Sparkle uses an older item only when the newest one does not apply (for example `minimumSystemVersion`), so the damage is small today. Each run also re-signs every old zip. The default keeps 3 items per branch (`S/generate_appcast/main.swift#L77`).

Items with no zip in the folder are removed (`S/generate_appcast/FeedXML.swift#L255-L287`). So `make clean` (`Makefile:97`) also removes the history.

Smallest fix: pass `--maximum-versions 1` at `Makefile:75`. Change T3 acceptance 5 to "one `<item>`, for the new release".

#### S3. The `edSignature` guard passes when only an old item is signed
- `Makefile:76`: `grep -q 'sparkle:edSignature='` matches any line in the file.
- `generate_appcast` only warns when the key in the app does not match the keychain key, and it leaves the item unsigned (`S/generate_appcast/Appcast.swift#L199-L209`).

Failure scenario: `HIJACK_SPARKLE_PUBKEY` is set to a wrong key in the shell (`build.sh:30`). The new item has no signature, but the old 1.2.0 item has one. The guard passes, and every client rejects 1.2.1.

Smallest fix: run the guard before the sed, on the new item only: `grep 'Hijack-$(VERSION)\.zip"' dist/appcast.xml | grep -q 'sparkle:edSignature='`. S2's fix also makes the current guard exact.

#### S4. A failure after "publish" cannot be resumed, and the cask step depends on the local zip
- After `Makefile:81`, the release is public. A failure in `brew audit` (`:86`) or `git push` (`:89`) leaves the cask on the old version.
- A re-run stops at the draft check (`Makefile:48-59`), so `make release` cannot finish the job.
- A hand fix must use the sha of the uploaded asset. A rebuild makes a zip with different bytes.

Smallest fix: move `Makefile:82-89` into a `cask` target. It downloads the published asset (`gh release download v$(VERSION) -p Hijack.zip`) and takes its sha. `release` calls it as the last step, and the maintainer can run it alone.

#### S5. Scheduled update alerts can appear behind other apps
- Hijack is `LSUIElement` (`build.sh:60`) and `.accessory` (`Sources/main.swift:18`). Sparkle treats it as a background app.
- When the app is not active, a scheduled alert opens behind other windows (`S/Sparkle/SPUStandardUserDriver.m#L268-L285`).
- Sparkle logs "Background app automatically schedules for update checks but does not implement gentle reminders" (`S/Sparkle/SPUStandardUserDriver.m#L161-L170`). See https://sparkle-project.org/documentation/gentle-reminders.

Failure scenario: the daily check finds 1.2.1 while the user types in another app. The alert is under that app's window. The user does not see it.

Smallest fix: pass a `userDriverDelegate` with `supportsGentleScheduledUpdateReminders = true`. In `standardUserDriverWillHandleShowingUpdate`, mark the menu bar icon or add a menu line. Or record in the spec that the behavior is accepted.

#### S6. `CFBundleVersion = <VERSION>.<git sha>` (planned on another branch) makes the order of builds with the same `VERSION` random
- Sparkle compares the appcast `sparkle:version` with the host `CFBundleVersion` (https://sparkle-project.org/documentation/publishing/). `generate_appcast` copies `CFBundleVersion` from the archive into `sparkle:version`.
- `SUStandardVersionComparator` splits a sha into number and letter parts. A number part beats a letter part, and letter parts compare as text (`S/Sparkle/SUStandardVersionComparator.m#L183-L276`).
- Builds with different `VERSION` values still compare correctly, because the first difference is in the numbers.
- Sparkle's publishing page says the internal version "is not generally suitable for … git changeset IDs".

Failure scenario: the release `1.2.1.9f3c2e1` is in the feed. A source build of a later commit is `1.2.1.a07b4d2`. The comparator says `9 > a`, so Sparkle offers the older release as an update. If the user accepts, the source build is replaced. The reverse order hides a real update.

A second effect: `SUSkippedVersion` then holds the sha form and never equals `displayVersionString` (M2).

Smallest fix: keep `CFBundleVersion` numeric and increasing, for example `git rev-list --count HEAD`, or the `VERSION` value alone. Put the sha in a custom Info.plist key (for example `HijackCommit`), and print it in `hijack version`.

### Nit

- **N1.** `build.sh:67` says the framework is signed "with the same identity as the app". Only the framework's top level is. `Autoupdate` and `Updater.app` keep Sparkle's ad-hoc signature. Sparkle accepts this: the update match uses the old app's designated requirement without nested code (`S/Autoupdate/SUCodeSigningVerifier.m#L73-L77`). The installer adds no requirement when it has no team ID (`#L445-L451`). Fix the comment, or sign `Autoupdate` and `Updater.app` first with the same identity. T3 acceptance 3 must still prove the install on a real update.
- **N2.** `build.sh:28` removes `Versions/B/XPCServices` but keeps the top-level symlink `Sparkle.framework/XPCServices`, which now points nowhere. `codesign --strict` accepts it today. Fix: also `rm -f "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"`.
- **N3.** `release` does not check for local changes. If the owner pastes the key in `assets/sparkle-public-key.txt` and does not commit it, the release builds from a tree that does not match the tag. Fix: `git diff --quiet HEAD || exit 1` after `Makefile:47`.
- **N4.** `Makefile:79`: the dots in `$(VERSION)` are regex wildcards. They are harmless here. If `SURequireSignedFeed` is set later, `generate_appcast` signs the whole feed (`S/generate_appcast/FeedXML.swift#L647-L650`), and the sed then breaks that signature. Put a comment on the sed.
- **N5.** The "Check Now" button (`Sources/Settings.swift:412`) stays enabled during a check. The menu item is disabled by Sparkle. Fix: observe `canCheckForUpdates` with KVO, as Sparkle's SwiftUI sample does.
- **N6.** `scripts/sparkle-test-feed.sh:18` uses a placeholder signature that is not base64. That tests "signature cannot be decoded", not "signed with a different key" (T3 acceptance 4). Sign with a second key from `generate_keys --account test`.
- **N7.** `HIJACK_SPARKLE_PUBKEY` (`build.sh:30`) overrides the file, but the release guard reads only the file (`Makefile:63`). Unset the variable in `release`, or check the value that `build.sh` used.
- **N8.** `UpdateNotice.compare` (`Sources/Core/UpdateNotice.swift:13-20`) maps a part with letters to 0. Sparkle orders `1.3.0b1` before `1.3.0`; this code says they are equal. Harmless while releases are numeric.
- **N9.** The cask in the tap is outside this diff. With Sparkle, Homebrew's documentation asks for `auto_updates true`, so that `brew upgrade` does not fight the in-app update.

---

## 3. New Core tests: mutation results

Scratch copy of `Package.swift`, `Sources/Core` and `UpdateNoticeTests.swift`. Baseline: 8 tests, 0 failures.

| Mutation in `UpdateNotice.swift` | Red test (assertion) |
|---|---|
| `== .orderedDescending` to `!= .orderedAscending` (report equal) | `testSameVersionIsNotReported` (`:10` `XCTAssertNil`), `testShorterVersionIsPaddedWithZeros` (`:29`) |
| `== .orderedDescending` to `!= .orderedSame` (report older) | `testOlderFoundVersionIsNotReported` (`:13`), `testNumericCompareNotLexical` (`:26`) |
| Remove the `" (skipped)"` suffix | `testSkippedVersionIsNamedAsSkipped` (`:16` `XCTAssertEqual`) |
| `skipped == found` to `skipped != nil` | `testSkippedOtherVersionDoesNotHideANewerOne` (`:19`) |
| `max(x.count, y.count)` to `min(...)` (no zero padding) | `testShorterVersionIsPaddedWithZeros` (`:30`) |
| `compare` returns `a.compare(b)` (lexical) | `testNumericCompareNotLexical` (`:25`, `:26`), `testShorterVersionIsPaddedWithZeros` (`:29`) |
| (none possible) | `testNothingFoundPrintsNothing`: the `guard let found` is enforced by the type system. No mutation that compiles can make it red. |

Result: 7 of 8 tests go red on a real mutation. All tests return to green after the restore.
The tests are good for `UpdateNotice`. They cannot catch M2, because M2 is in the input that the CLI reads.

---

## 4. Verdict

**Merge after fixes.** Fix M1, M2 and M3 before merge. M1 needs the owner's `generate_keys` step, or the build-side guard.
Fix S1-S4 before the first `make release` of 1.2.0, because they are in the release path.
S5 and S6 can follow in 1.2.1. S6 must be settled before the `<VERSION>.<sha>` branch lands.
