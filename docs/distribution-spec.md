# Distribution spec: Makefile, CI, Sparkle

Date: 2026-10-03. Owner decisions recorded in §2. Research with sources: `briefs/dist-research-2026-10-03.md`
(not in git). Status: approved WHAT, HOW ready for tickets.

## 1. Why

Hijack 1.1.4 ships by hand: `release.sh` on the owner's Mac, then a hand edit of the cask. Users learn about a
new version only from the brew cask or the releases page. A source build needs a script the user has to find.
Three gaps:

1. The app cannot tell the user that an update exists.
2. A source install has no standard entry point.
3. Nothing runs the tests or the build on each push. A broken main is found at release time.

## 2. Decisions

| # | Decision | Chosen | Why |
|---|---|---|---|
| D1 | Private keys in CI | **No.** The self-signed "Hijack Signing" key and the Sparkle EdDSA key stay in the owner's login keychain | The self-signed certificate has no revocation path. A GitHub secret cannot be rotated the way an Apple-issued certificate can |
| D2 | What CI does | Tests and an ad-hoc build on every push and pull request. A **draft** release on a `v*` tag, with notes and no binary | Follows from D1. The signed zip, the Sparkle signature and the appcast come from the owner's Mac |
| D3 | Where the release finishes | `make release` on the owner's Mac. It builds, signs, zips, signs for Sparkle, writes the appcast, uploads both assets, publishes the draft, and bumps the cask | One command replaces `release.sh` plus the hand edit |
| D4 | appcast hosting | A release asset: `https://github.com/zl190/hijack/releases/latest/download/appcast.xml` | No extra hosting. GitHub redirects `latest` to the newest release. The appcast is re-uploaded on every release |
| D5 | `brew install --HEAD` | **Not provided.** `make install` is the source path | A cask cannot carry `head`. A formula named `hijack` would collide with the cask in the same tap. A formula that installs a `.app` is outside what the Formula Cookbook supports |
| D6 | Sparkle version and embedding | Sparkle 2.10.0 from the release `.tar.xz`, pinned by sha256. `Package.swift` links it (`swiftc -F` until ADR 0020) and embeds `Sparkle.framework` in `Contents/Frameworks`. The XPC services are dropped (the app is not sandboxed). The framework is re-signed with the app identity | No Xcode project. The exact `swiftc` flags are not in any official doc; ticket T3 verifies them on the first build |
| D7 | Update checks | `SUEnableAutomaticChecks` true in Info.plist (no second-launch prompt), `SUScheduledCheckInterval` 86400, `SUAutomaticallyUpdate` false. Menu: "检查更新…" / "Check for Updates…". Settings › General gets an "Updates" card: "自动检查更新" / "Check for updates automatically" (default on), "自动下载并安装" / "Download and install automatically" (default off), a "现在检查" / "Check Now" button, and the version | The two toggles bind to `SPUUpdater.automaticallyChecksForUpdates` and `automaticallyDownloadsUpdates`; Sparkle stores them. Same shape as Rectangle, Maccy and Stats. The check is a frequent action, so it is in the menu; the toggles are set once, so they are in Settings |
| D8 | Scripts | `build.sh` stays (it is the build). `install-from-source.sh` and `release.sh` fold into the Makefile and are deleted. `install.sh` (the curl installer for users) stays | One entry point for maintainers, one script for end users |

## 3. What

### T1. Makefile

Targets, all `.PHONY`:

| Target | Does | Replaces |
|---|---|---|
| `make build` | `./build.sh` | — |
| `make test` | `swift test` | — |
| `make install` | build, quit the running app, copy to `/Applications`, open it, link `hijack` into `~/.local/bin` when on PATH | `install-from-source.sh` |
| `make release` | D3, in this order: check `VERSION` == the draft tag, signed build, zip, `sign_update`, `generate_appcast`, `gh release upload`, `gh release edit --draft=false`, bump the cask and push the tap | `release.sh` + the hand edit |
| `make diagrams` | `scripts/diagrams.sh` | — |
| `make clean` | remove `build/`, `dist/` | — |

Variables: `SIGN_ID` (default `Hijack Signing` for `release`, empty for `build` and `install` so a dev build
stays ad-hoc). `make release` refuses to run when the identity is not in the keychain.

Acceptance (EARS):

1. When the user runs `make install` on a clean checkout with Command Line Tools, the app shall be in `/Applications` and running. `hijack status` shall then print `running`.
2. When `make release` runs and `VERSION` differs from the newest draft release tag, it shall stop before building and name both values.
3. When `make release` runs without the signing identity in the keychain, it shall stop before building.
4. When `make release` completes, the release shall carry `Hijack.zip` and `appcast.xml` and shall not be a draft. The cask shall carry the new version and the sha256 of that zip.
5. The README and `docs/usage.md` shall name `make install` as the source path and shall not name `install-from-source.sh`.

### T2. GitHub Actions

Two workflows.

`ci.yml`, on push and pull request to `main`:

1. Runner `macos-15`.
2. `swift test`.
3. `./build.sh` with no identity (ad-hoc).
4. Upload `build/Hijack.app` zipped as an artifact, kept 7 days. The artifact is evidence, not a release.

`release.yml`, on a tag `v*`:

1. Check that `VERSION` equals the tag without `v`. Fail otherwise.
2. Check that `release-notes/v<VERSION>.md` exists. Fail otherwise.
3. `gh release create v<VERSION> --draft --title "Hijack <VERSION>" --notes-file release-notes/v<VERSION>.md`. Needs `permissions: contents: write`.

Acceptance:

1. When a push changes a test so that it fails, the `ci` check on that commit shall be red.
2. When a tag `v1.2.0` is pushed with `VERSION` 1.2.0 and its notes file, a draft release `v1.2.0` shall exist with those notes and no assets.
3. When a tag is pushed and `VERSION` does not match, the workflow shall fail and shall create no release.
4. The README shall show the `ci` badge.

### T3. Sparkle

1. `build.sh` downloads `Sparkle-2.10.0.tar.xz` into `.sparkle/` (git-ignored) when absent and checks its sha256. It links with `-F .sparkle -framework Sparkle` and `-rpath @executable_path/../Frameworks`. It copies `Sparkle.framework` into `Contents/Frameworks` without `XPCServices`. It re-signs the framework, then signs the app.
2. `Info.plist` gains `SUFeedURL` (D4), `SUPublicEDKey`, `SUEnableAutomaticChecks`, `SUScheduledCheckInterval`.
3. `Menu.swift` creates one `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)` and adds "检查更新…" / "Check for Updates…" above "设置…" / "Settings…", target the controller, action `checkForUpdates(_:)`. `Settings.swift` adds the "Updates" card from D7; the toggles read and write `updater.automaticallyChecksForUpdates` and `updater.automaticallyDownloadsUpdates`.
4. `hijack version` prints the running version. When the last check found a newer one, it prints that too, read from Sparkle's user defaults. The CLI makes no network call.
5. `make release` writes `appcast.xml` with `generate_appcast` over `dist/`, which signs the archive with the key from the keychain. The release notes are the Markdown file next to the zip, embedded with `--embed-release-notes` (Sparkle renders `sparkle:format="markdown"`). No HTML file and no `pandoc`.
6. The cask keeps working. Sparkle and brew both replace `/Applications/Hijack.app`; the relauncher LaunchAgent opens the app only when it is not running, so Sparkle's own relaunch wins. T3 verifies this on a real update (acceptance 3).
7. One-time owner step, by hand: `generate_keys` (stores the EdDSA key in the login keychain, prints the public key for `SUPublicEDKey`).

Acceptance:

1. When the app starts, `otool -L` on the binary shall list `@rpath/Sparkle.framework/Versions/B/Sparkle`, and the app shall start with no missing-library error.
2. Given the feed URL points at a local server (`defaults write com.zl190.hijack SUFeedURL http://127.0.0.1:8000/appcast.xml`) that lists a higher version signed with the same key: when the user chooses "Check for Updates…", Sparkle shall show the update with the release notes.
3. When the user accepts that update, the new version shall be in `/Applications` and running within 30 s. Exactly one Hijack process shall exist. `hijack status` shall print `accessibility allowed` without a new grant.
4. When the appcast entry is signed with a different key, Sparkle shall refuse the update and shall say so.
5. When `make release` runs, `appcast.xml` shall validate: one `<item>`, for the new release, with `sparkle:edSignature` and `length`.
6. The first dictation after the update shall produce a summary line in the log (the tap works under the new signature).
7. When the user turns "Check for updates automatically" off in Settings, `defaults read com.zl190.hijack SUEnableAutomaticChecks` shall print 0, and no scheduled check shall run.

## 4. How, order and ownership

| Ticket | Files (expected) | Who | Depends on |
|---|---|---|---|
| T1 Makefile | Makefile, README.md, docs/usage.md, delete install-from-source.sh and release.sh, .gitignore (`.sparkle/`, `dist/`) | builder | — |
| T2 Actions | .github/workflows/ci.yml, release.yml, README.md badge | builder | T1 (`make test`, `make build`) |
| T3 Sparkle | build.sh, Sources/Menu.swift, Sources/CLI.swift, Makefile (`release` gains sign_update and generate_appcast), docs/usage.md, release-notes/v1.2.0.md | lead, because the swiftc flags and the relaunch interaction need a live check | T1 |

Version plan: T1 and T2 ship as docs and tooling with no app change; they can land before a release. T3 is
the 1.2.0 release. 1.2.0 cannot update itself from 1.1.4 (1.1.4 has no Sparkle); the first in-app update is
1.2.0 → 1.2.1.

Out of scope: notarization, Developer ID, a formula for `--HEAD`, delta updates, Sparkle's sandbox XPC
services, automatic installs (`SUAutomaticallyUpdate`).

## 5. Risks

| Risk | Check | Fallback |
|---|---|---|
| `swiftc -F/-framework` does not link Sparkle without Xcode | T3 acceptance 1 on the first build | Build Sparkle from source with its `make release`, or move the app to SwiftPM |
| The relauncher and Sparkle both open the app | T3 acceptance 3 (one process) | The relauncher skips when a Sparkle install is in progress (Sparkle's installer writes to `/Applications/Hijack.app` atomically; the agent's inode check then sees one change) |
| The self-signed identity fails Sparkle's designated-requirement check | T3 acceptance 3 | None known. The check compares the running app's requirement with the new one; the same certificate satisfies it |
| `releases/latest/download` serves a pre-release | Never mark a release as pre-release | Host the appcast on GitHub Pages |
