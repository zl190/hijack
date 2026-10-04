# Threat model

Date: 2026-10-04. Scope: the running app and the `hijack` CLI. Written in ASD-STE100 English: one topic
per sentence, plain words, active voice. Every control below cites the file and line that enforces it.

## 1. Assets

The key tap sees every key event on the system, in every app, including password fields (`Sources/System.swift:99-128`).
It is the single most sensitive thing Hijack touches: it runs before any other app sees the key.

The log (`~/Library/Logs/Hijack.log`) stores only key **kinds**: "our talk key", "the shortcut", or "another
key" (`Sources/System.swift:119`). It never stores a raw key code from an event we did not post ourselves.
It does store the trigger key's and the talk key's own ids, because the user chose them
(`Sources/Core/Engine.swift:350-368`, `Sources/Core/Keys.swift:78-81`).

`state.json` (`~/Library/Application Support/Hijack/state.json`) holds `pid`, `trusted`, `tapActive`,
`secureInput`, `secureInputApp`, `updated` (`Sources/AppState.swift:10-18`). The app, not the CLI, can read
whether Accessibility is granted; the CLI reads this file instead (`Sources/AppState.swift:3-4`).

`config.json` (`~/.config/hijack/config.json`) holds `trigger`, `voiceInput`, `voiceKeys`, `triggerMode`,
`stopOnAnyKey`, `voiceStyles`, `showMenuBarIcon`, `showDockIcon`, `language`, `holdDelay`, `restoreTimeout`,
`fallbackDelay` (`Sources/Config.swift:13-29`). None of these fields are secrets.

## 2. Trust boundaries

**The tap.** `CGEvent.tapCreate` sits ahead of every other app (`place: .headInsertEventTap`,
`Sources/System.swift:103-104`). Code inside this process can read and forge any key on the system.

**The voice tool's settings files, read-only.** Hijack reads WeType's MMKV store
(`Sources/Providers.swift:12-16`) and Handy's `settings_store.json` (`Sources/Providers.swift:118-123`) to
find the user's own talk key. It never writes either file.

**The appcast, over HTTPS.** Sparkle fetches `SUFeedURL`, a GitHub Releases URL
(`build.sh:85`), and checks its EdDSA signature against the public key embedded in the app
(`build.sh:46`). A party without the matching private key cannot author an update Sparkle will accept.

**The self-signed identity.** `Hijack Signing` lives only in the owner's login keychain, by decision
(`docs/distribution-spec.md:20`, D1). CI never holds it; every release is signed on the owner's Mac.

## 3. STRIDE

| # | Category | Threat | Control (file:line) or GAP (ticket) |
|---|---|---|---|
| 1 | Spoofing | Another local process forges a CGEvent with Hijack's `marker` tag to fake "our own key came back" | GAP: `marker` is a fixed public constant (`Sources/Shared.swift:8`), not a secret. Accepted below (§5) — forging it needs the same Accessibility grant that already lets a process inject any key |
| 2 | Spoofing | A second `hijack` process starts (bare or mistyped command) and writes its own `state.json`, confusing `status`/`doctor` about which process is real | GAP `single-instance-and-cli-typo` (`docs/review-5/senior-audit.md` #1); not in this wave |
| 3 | Tampering | A hand edit of `config.json` sets an absurd or malformed value | Control: invalid JSON is rejected and the previous settings stay in effect (`Sources/Config.swift:40-49`); numeric fields are clamped to range on load (`Sources/Core/ConfigValues.swift:21-27`) |
| 4 | Tampering | Another local process (same user) overwrites `state.json` to claim `trusted`/`tapActive` are true when they are not | GAP: `AppState.read()` only checks that the recorded `pid` is alive (`Sources/AppState.swift:52`), not who wrote the file. Accepted below (§5) — standard same-user file trust |
| 5 | Repudiation | The log can be edited or deleted by the same local user, hiding what happened | GAP: `log()` opens the file for append with no integrity check (`Sources/Shared.swift:61-65`). Accepted below (§5) |
| 6 | Repudiation | A setting change made through the CLI is denied later | Control: every `hijack set` writes a dated log line before it prints its result (`Sources/CLI.swift:293`) |
| 7 | Information disclosure | The tap's own debug line could leak which key was pressed | Control: the line names only a kind, never a code, for a key that is not ours (`Sources/System.swift:118-121`) |
| 8 | Information disclosure | The per-dictation log line names the front app, a record of where the user dictated | GAP `log-ids-not-names`'s sibling finding, `doctor-report` (`docs/review-5/senior-audit.md` #10, `Sources/Core/Engine.swift:368`); not in this wave |
| 9 | Denial of service | Another process holds Secure Event Input; the shortcut then does nothing, in every app, until it is released | Control: FM-03 (`docs/fmea.md:84`); detection is a summary-line note and a menu line only (§4 below), not a push alert |
| 10 | Denial of service | The system disables the tap under load (a slow callback) | Control: `reenableTap` retries once on the next run-loop turn and logs either outcome (`Sources/Core/Engine.swift:438-459`) |
| 11 | Elevation of privilege | `DYLD_INSERT_LIBRARIES` loads foreign code into a process that already holds Accessibility and the tap | GAP `hardened-runtime` (`docs/review-5/senior-audit.md` #5, `build.sh:93-94` sign with no `--options runtime`); ticket W6 |
| 12 | Elevation of privilege | `install.sh` downloads and runs a release asset with no integrity check | GAP `verify-download-identity` (`docs/review-5/senior-audit.md` #15, `install.sh:6-11`); ticket W4 |

## 4. Secure Input

macOS stops delivering key events to every tap, including ours, while another process holds Secure Event
Input (a password field, some terminals). The shortcut does nothing, in every app, until that process
releases it. This is an OS guarantee, not a Hijack control: FM-03 (`docs/fmea.md:84`).

Hijack reads the current state with `IsSecureEventInputEnabled()` (`Sources/System.swift:97`). It does not
poll it continuously. It checks it at the end of a dictation's summary line (`Sources/Core/Engine.swift:367`)
and when the menu opens (`Sources/Menu.swift:184-187`). Between those moments the value can be stale
(`Sources/AppState.swift:14-16`).

## 5. What the CLI exposes

`hijack status --json` prints `secureInput` and `secureInputApp` from `state.json`
(`Sources/CLI.swift:129`), as of the last menu open or dictation summary, never a password or its field name.

`hijack stats --json` prints only aggregated counts and timing percentiles per voice tool
(`Sources/CLI.swift:334-346`, `Sources/Core/Stats.swift:83-91`). It carries no front-app name and no key code;
the per-dictation front app stays in the plain-text log only (`Sources/Core/Engine.swift:368`), read with
`hijack log`.

`hijack doctor` checks config validity, whether Hijack is running, Accessibility, the tap, the voice source,
and the talk key (`Sources/CLI.swift:155-195`). It does not report Secure Input; only `status` does.

## 6. Residual risks the owner accepts

The self-signed signing key and the Sparkle EdDSA key live only in the owner's login keychain, by decision
D1 (`docs/distribution-spec.md:20`). Losing that keychain stops updates and the signing path, with no CI
fallback. The owner accepts this: a GitHub secret cannot be rotated the way an Apple-issued certificate can.

`build.sh` signs ad-hoc, with no hardened runtime, until ticket W6 lands (`build.sh:93-94`). The owner
accepts this gap for the length of the current wave.

`install.sh` fetches `Hijack.zip` over HTTPS and runs it with no checksum or signature check, until ticket
W4 lands (`install.sh:6-11`). The owner accepts this gap for the length of the current wave.

`state.json` and `config.json` carry the permissions of an ordinary per-user file
(`Sources/AppState.swift:7-9`, `Sources/Config.swift:9`). Any process running as the same user can read or
write them. The owner accepts this as the normal posture for an unsandboxed, single-user utility.

The `marker` constant that tags Hijack's own posted events is a fixed value in open source
(`Sources/Shared.swift:8`), not a secret. A process that forged it would already need the Accessibility
grant that lets it inject any key directly, so forging it adds no new capability. The owner accepts this.

The log (`~/Library/Logs/Hijack.log`) is plain text, append-only by convention, and not tamper-evident
(`Sources/Shared.swift:61-65`). It also names the front app per dictation (`Sources/Core/Engine.swift:368`),
a record of where the user dictated. The owner accepts both, pending `doctor-report`
(`docs/review-5/senior-audit.md` #10), not scheduled this wave.

Secure Input detection is passive: a summary-line note or a menu line, never a push notification
(`docs/fmea.md:84`, `:136`). The owner accepts this; FM-03's own detection column says "manual".
