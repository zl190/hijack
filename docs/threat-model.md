# Threat model

Date: 2026-10-04 (review 6: cites refreshed for `wave-w5`, rows 2 and 12 corrected, three rows added).
Scope: the running app and the `hijack` CLI. Written in ASD-STE100 English: one topic per sentence, plain
words, active voice. Every control below cites the file and line that enforces it.

## 1. Assets

The key tap sees every key event on the system, in every app, including password fields
(`Sources/App/System.swift:109-144`). It is the single most sensitive thing Hijack touches: it runs before
any other app sees the key.

The log (`~/Library/Logs/Hijack.log`) stores only key **kinds**: "our talk key", "the shortcut", or "another
key" (`Sources/App/System.swift:135`). It never stores a raw key code from an event we did not post ourselves.
It does store the trigger key's and the talk key's own ids, because the user chose them
(`Sources/Core/Engine.swift:359-384`, `Sources/Core/Keys.swift:88-91`).

`~/Library/Logs/Hijack-metrics` holds MetricKit's crash and hang diagnostics, one JSON file per delivery
(`Sources/App/Metrics.swift:10`, `:23`). Apple's own payload: a call-stack tree for Hijack's own process, no
keystrokes. It is written unencrypted and kept unread until `hijack doctor` or `hijack stats` reads it back.

`state.json` (`~/Library/Application Support/Hijack/state.json`) holds `pid`, `trusted`, `tapActive`,
`secureInput`, `secureInputApp`, `updated` (`Sources/App/AppState.swift:11-19`). The app, not the CLI, can read
whether Accessibility is granted; the CLI reads this file instead (`Sources/App/AppState.swift:4-6`).

`config.json` (`~/.config/hijack/config.json`) holds `trigger`, `voiceInput`, `voiceKeys`, `triggerMode`,
`stopOnAnyKey`, `voiceStyles`, `showMenuBarIcon`, `showDockIcon`, `language`, `holdDelay`, `restoreTimeout`,
`fallbackDelay` (`Sources/App/Config.swift:14-30`). None of these fields are secrets.

The build's own identity. `HijackCommit` in Info.plist is the git sha, `+dirty` if the tree had uncommitted
changes (`build.sh:14-16`, `:77`). `hijack version` and `hijack status` print it; a crash report correlates to
it. It is a plain string: nothing signs it, so it identifies a build, and does not authenticate one.

## 2. Trust boundaries

**The tap.** `CGEvent.tapCreate` sits ahead of every other app (`place: .headInsertEventTap`,
`Sources/App/System.swift:113-114`). Code inside this process can read and forge any key on the system.

**The voice tool's settings files, read-only.** Hijack reads WeType's MMKV store
(`Sources/App/Providers.swift:13-17`) and Handy's `settings_store.json` (`Sources/App/Providers.swift:119-124`)
to find the user's own talk key. It never writes either file.

**The appcast, over HTTPS.** Sparkle fetches `SUFeedURL`, a GitHub Releases URL
(`build.sh:80`), and checks its EdDSA signature against the public key embedded in the app
(`build.sh:41`). A party without the matching private key cannot author an update Sparkle will accept.

**The self-signed identity.** `Hijack Signing` lives only in the owner's login keychain, by decision
(`docs/distribution-spec.md:20`, D1). CI never holds it; every release is signed on the owner's Mac.

## 3. STRIDE

| # | Category | Threat | Control (file:line) or GAP (ticket) |
|---|---|---|---|
| 1 | Spoofing | Another local process forges a CGEvent with Hijack's `marker` tag to fake "our own key came back" | GAP: `marker` is a fixed public constant (`Sources/App/Shared.swift:9`), not a secret. Accepted below (§6) — forging it needs the same Accessibility grant that already lets a process inject any key |
| 2 | Spoofing | A second `hijack` process starts and installs a second tap, confusing `status`/`doctor` about which process is real | CONTROL since review 6: an exclusive `flock` on `instance.lock` makes a second launch find the lock held and exit at once, with no tap installed and no `state.json` write (`Sources/App/main.swift:19-41`). Narrower residual gap: a bare or mistyped `hijack` command, with **no** instance running, still falls through and starts the full app (`Sources/App/CLI.swift:10-14`, `Sources/App/main.swift:14`); not fixed this wave |
| 3 | Tampering | A hand edit of `config.json` sets an absurd or malformed value | Control: invalid JSON is rejected and the previous settings stay in effect (`Sources/App/Config.swift:41-50`); numeric fields are clamped to range on load (`Sources/Core/ConfigValues.swift:23-29`) |
| 4 | Tampering | Another local process (same user) overwrites `state.json` to claim `trusted`/`tapActive` are true when they are not | GAP: `AppState.read()` only checks that the recorded `pid` is alive (`Sources/App/AppState.swift:53`), not who wrote the file. Accepted below (§6) — standard same-user file trust |
| 5 | Tampering | A party other than the owner tampers with the appcast or the update package, in transit or on GitHub | Control: the appcast travels over HTTPS (`build.sh:80`) and Sparkle checks its EdDSA signature against the public key the app was built with (`build.sh:41`). A party without the matching private key (owner's login keychain only, D1) cannot author an update Sparkle will accept |
| 6 | Repudiation | The log can be edited or deleted by the same local user, hiding what happened | GAP: `log()` opens the file for append with no integrity check (`Sources/App/Shared.swift:62-66`). Accepted below (§6) |
| 7 | Repudiation | A setting change made through the CLI is denied later | Control: every `hijack set` writes a dated log line before it prints its result (`Sources/App/CLI.swift:319`) |
| 8 | Repudiation | A locally built or modified binary claims to be a given version | GAP: `HijackCommit` (§1) names a commit but is just a string baked in at build time (`build.sh:14-16`, `:77`); nothing signs it, so a modified binary can claim any value. Accepted below (§6) — `codesign`'s own signature is the thing that is actually checked (`install.sh:38-52`) |
| 9 | Information disclosure | The tap's own debug line could leak which key was pressed | Control: the line names only a kind, never a code, for a key that is not ours (`Sources/App/System.swift:134-136`) |
| 10 | Information disclosure | The per-dictation log line names the front app, a record of where the user dictated | GAP `log-ids-not-names`'s sibling finding, `doctor-report` (`docs/review-5/senior-audit.md` #10, `Sources/Core/Engine.swift:382`); not in this wave |
| 11 | Denial of service | Another process holds Secure Event Input; the shortcut then does nothing, in every app, until it is released | Control: FM-03 (`docs/fmea.md:84`); detection is a summary-line note and a menu line only (§4 below), not a push alert |
| 12 | Denial of service | The system disables the tap under load (a slow callback) | Control: `reenableTap` retries once on the next run-loop turn and logs either outcome (`Sources/Core/Engine.swift:452-473`) |
| 13 | Elevation of privilege | `DYLD_INSERT_LIBRARIES` loads foreign code into a process that already holds Accessibility and the tap | ACCEPTED, not fixable with a self-signed identity: library validation compares Team IDs, and a self-signed certificate has none, so the app does not start with `--options runtime` (ADR 0021, live test 2026-10-04) |
| 14 | Elevation of privilege | `install.sh` downloads and runs a release asset with no integrity check | PARTIAL CONTROL since W4, narrower than first stated: the checksum detects corruption or a single swapped file inside the same release (`install.sh:16-29`); it cannot stop an attacker who controls the release upload, since they would publish a matching checksum too. The authority check compares a certificate **common name** string (`install.sh:44-51`); anyone can create a self-signed certificate also named "Hijack Signing". Both checks catch mistakes and opportunistic swaps, not a party who can publish releases |
| 15 | Elevation of privilege | SwiftPM's release build adds rpaths that let a planted library at `/Applications/Xcode.app/.../Sparkle.framework/...` load before Hijack's own bundled copy (review 6, M1) | CONTROL since review 6: `build.sh` deletes every rpath except `/usr/lib/swift` and `@executable_path/../Frameworks`, then asserts the exact pair or fails the build (`build.sh:27-34`) |

## 4. Secure Input

macOS stops delivering key events to every tap, including ours, while another process holds Secure Event
Input (a password field, some terminals). The shortcut does nothing, in every app, until that process
releases it. This is an OS guarantee, not a Hijack control: FM-03 (`docs/fmea.md:84`).

Hijack reads the current state with `IsSecureEventInputEnabled()` (`Sources/App/System.swift:107`). It does
not poll it continuously. It checks it at the end of a dictation's summary line
(`Sources/Core/Engine.swift:381`) and when the menu opens (`Sources/App/Menu.swift:188-192`). Between those
moments the value can be stale (`Sources/App/AppState.swift:15-17`).

## 5. What the CLI exposes

`hijack status --json` prints `secureInput` and `secureInputApp` from `state.json`
(`Sources/App/CLI.swift:142`), as of the last menu open or dictation summary, never a password or its field
name.

`hijack stats --json` prints aggregated counts and timing percentiles per voice tool
(`Sources/App/CLI.swift:362-380`, `Sources/Core/Stats.swift:83-92`). Since W3 it also carries a `system` block:
MetricKit's hang count, crash count and last crash date, CPU seconds per day, and peak memory
(`Sources/App/CLI.swift:368`, `:423-431`) — counts and durations, never a call stack. It carries no front-app
name and no key code; the per-dictation front app stays in the plain-text log only
(`Sources/Core/Engine.swift:382`), read with `hijack log`.

`hijack doctor` checks config validity, whether Hijack is running, Accessibility, the tap, the voice source,
the talk key, and (since W3) warns when a crash report post-dates the last recorded start
(`Sources/App/CLI.swift:168-215`). It does not report Secure Input; only `status` does.

## 6. Residual risks the owner accepts

The self-signed signing key and the Sparkle EdDSA key live only in the owner's login keychain, by decision
D1 (`docs/distribution-spec.md:20`). Losing that keychain stops updates and the signing path, with no CI
fallback. The owner accepts this: a GitHub secret cannot be rotated the way an Apple-issued certificate can.

`build.sh` signs with no hardened runtime. W6 tried it and the app did not start (ADR 0021). The owner
accepts this gap for the length of the current wave.

`install.sh` verifies a checksum and a certificate common name since W4. Row 14 (§3) restates what that
does and does not stop: corruption and a single swapped asset, not a party who can publish releases.
Releases before 1.2.0 carry no checksum file, so the installer refuses them with a clear message.

`HijackCommit` identifies a build; it does not authenticate one (row 8, §3). The owner accepts this: the
thing that is actually checked before install is `codesign`'s own signature (`install.sh:38-42`), not this
string.

`state.json` and `config.json` carry the permissions of an ordinary per-user file
(`Sources/App/AppState.swift:8-9`, `Sources/App/Config.swift:10`). Any process running as the same user can
read or write them. The owner accepts this as the normal posture for an unsandboxed, single-user utility.

The `marker` constant that tags Hijack's own posted events is a fixed value in open source
(`Sources/App/Shared.swift:9`), not a secret. A process that forged it would already need the Accessibility
grant that lets it inject any key directly, so forging it adds no new capability. The owner accepts this.

The log (`~/Library/Logs/Hijack.log`) is plain text, append-only by convention, and not tamper-evident
(`Sources/App/Shared.swift:62-66`). It also names the front app per dictation (`Sources/Core/Engine.swift:382`),
a record of where the user dictated. The owner accepts both, pending `doctor-report`
(`docs/review-5/senior-audit.md` #10), not scheduled this wave.

A mistyped CLI command starts the full app when no instance is already running (row 2, §3), instead of
printing an error. The owner accepts this; `single-instance-and-cli-typo`
(`docs/review-5/senior-audit.md` #1) covers the rest of that finding and is not scheduled this wave.

Secure Input detection is passive: a summary-line note or a menu line, never a push notification
(`docs/fmea.md:84`, `:136`). The owner accepts this; FM-03's own detection column says "manual".
