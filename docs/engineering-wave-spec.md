# Engineering wave spec: SwiftPM, MetricKit, threat model, property test, SLO, force unwraps, hardened runtime, install check

Date: 2026-10-04. Source of the items: the owner's 2026 practice list and `docs/review-5/senior-audit.md`.
Status: approved by the owner on 2026-10-04 ("先把这些做了").

## 1. Why

The app has tests, seams and reviews. Four engineering layers are still missing: one build system
(SwiftPM), system diagnostics (MetricKit), a written security boundary (threat model), and a stated
reliability target (SLO). Three audit items close known holes: force unwraps on the hot path, no hardened
runtime, and an installer that trusts the network.

## 2. Tickets

| Id | Ticket | Files (expected) | Who | Order |
|---|---|---|---|---|
| W1 | SwiftPM app target | Package.swift, Sources/App/* (moved from Sources/*), build.sh, scripts/diagrams.sh, .swiftplantuml.yml, Makefile, docs | lead (fork) | first, alone |
| W2 | Threat model, property test, SLO | docs/threat-model.md, Tests/HijackCoreTests/PropertyTests.swift, Sources/Core/Stats.swift, Sources/CLI.swift (stats lines), docs/usage.md | builder | parallel with W1 |
| W3 | MetricKit | Sources/Metrics.swift (new), Sources/Core/MetricsSummary.swift (new), Sources/CLI.swift (stats, doctor), docs/usage.md | builder | parallel with W1 |
| W4 | install.sh verification | install.sh, Makefile (release-assets publishes Hijack.zip.sha256), docs/usage.md | builder | parallel with W1 |
| W5 | Force unwraps | Sources/**, .swift-format (NeverForceUnwrap on) | builder | after W1 |
| W6 | Hardened runtime | build.sh (`-o runtime`), docs/threat-model.md | lead, live test | done: rejected, ADR 0021 |

## 3. What, per ticket

### W1 SwiftPM app target

1. Package.swift gains `executableTarget(name: "Hijack", dependencies: ["HijackCore"], path: "Sources/App")`. The eleven AppKit files move from `Sources/` to `Sources/App/`. `main.swift` stays the entry.
2. Sparkle links through the package: `swiftSettings: [.unsafeFlags(["-F", ".sparkle/<version>"])]` and `linkerSettings: [.unsafeFlags(["-F", ".sparkle/<version>", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]), .linkedFramework("Sparkle")]`. build.sh downloads Sparkle before `swift build` as today.
3. build.sh runs `swift build -c release --product Hijack` and copies the binary into the bundle. The bundle assembly (Info.plist, icon, Sparkle embed, codesign) stays in build.sh.
4. `swift test` keeps testing HijackCore only. `scripts/diagrams.sh` passes the package root once; Core types appear once in the class diagram.
5. Acceptance: `make build` produces the same bundle layout as before; `otool -L` lists Sparkle; `make test` 125 green; `hijack version` runs from the bundle; `swiftplantuml` output lists `Engine` once; CI green.

### W2 Threat model, property test, SLO

Threat model (`docs/threat-model.md`, ASD-STE100): assets (what the key tap sees: every key event on the system; what the log stores: key kinds and the trigger and talk key ids, never other key codes; state.json fields; config.json fields), trust boundaries (the tap, the voice tool's settings files read-only, the appcast over HTTPS, the self-signed identity), threats per STRIDE row with the control that exists or the gap, Secure Input behavior, what `hijack stats --json` and `doctor` expose, and the residual risks the owner accepts. Cite file:line for each control.

Property test (`Tests/HijackCoreTests/PropertyTests.swift`): a seeded random generator drives `SessionMachine` through 10,000 sequences of events (press, release, otherKey, keySent, textDone, switchFailed, quit) with random modes. Invariants: after `quit` the state is idle; `releaseTalkKey` never appears twice without a `sendTalkKey` between; every `sendTalkKey` is followed by `releaseTalkKey` or `finish` before the next `begin`; in hold mode a `release` from `listening` always yields `releaseTalkKey`. A failing sequence prints its seed and the sequence. Each invariant has a mutation check.

SLO: `hijack stats` prints `target  success >= 99.0%  this period 100.0%  met` (or `not met`). The target lives in `Stats.swift` as a constant with a comment that it is provisional until 7 days of 1.2.x data. `--json` carries `target` and `met`. Acceptance: StatsTests cover met and not met at the boundary (99.0 exactly is met).

### W3 MetricKit

1. `Sources/Metrics.swift`: `MXMetricManager.shared.add(subscriber)` at launch; `didReceive(_ payloads: [MXMetricPayload])` and `didReceive(_ payloads: [MXDiagnosticPayload])` write each payload's `jsonRepresentation()` to `~/Library/Logs/Hijack-metrics/<ISO date>-<metric|diagnostic>.json`. Keep 30 files, delete older. Log one line per delivery.
2. `Sources/Core/MetricsSummary.swift`: parses those JSON files (pure Foundation) into counts: hang diagnostics (count, longest), crash diagnostics (count, last date), CPU time per day, memory peak. Tests with fixture JSON (minimal hand-written payloads; MetricKit's format is documented).
3. `hijack stats` gains a "System (MetricKit)" block from the summary when files exist; `hijack doctor` warns when a crash diagnostic is newer than the last start.
4. Acceptance: tests on the parser with fixtures; `make build` green; the subscriber never runs on the tap path; a note in `docs/usage.md` that payloads arrive about once a day.

### W4 install.sh verification

1. `make release-assets` also writes `dist/Hijack.zip.sha256` (`shasum -a 256`) and uploads it.
2. `install.sh` downloads `Hijack.zip` and `Hijack.zip.sha256`, verifies the sum, then verifies the signature after unzip: `codesign --verify --strict` and `codesign -dv` must show `Authority=Hijack Signing`; on any mismatch it stops before touching /Applications and prints what differed.
3. Acceptance: a shell test `scripts/test-install.sh` that runs install.sh against a local HTTP server with a tampered zip and asserts refusal, and with a good zip asserts the verify step passes (without the /Applications step, via a `HIJACK_INSTALL_DIR` override).

### W5 Force unwraps

Turn `NeverForceUnwrap` on in `.swift-format`. For each of the 77 hits: on the key-tap path, replace with a guard and a logged fallback; off the path, replace when a value is not provable, keep with a `// swift-format-ignore: NeverForceUnwrap` and a one-line reason when it is (a static table lookup with a test that proves every key exists). Acceptance: `make lint` 0; the number of ignores is listed in the commit body with reasons; tests green.

### W6 Hardened runtime

Result (2026-10-04): not shipped. The live test failed at launch: library validation rejects the embedded framework because a self-signed identity has no Team ID. See ADR 0021. The flag returns when the identity is a Developer ID.

## 4. Out of scope

Notarization, Developer ID, SwiftLint, a universal binary, delta updates.
