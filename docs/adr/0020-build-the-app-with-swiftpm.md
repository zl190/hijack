# 0020. Build the app with SwiftPM

- Topic: Distribution and signing
- Status: Accepted
- Date: 2026-10-04
- Evidence: b50809a, Package.swift, build.sh, docs/engineering-wave-spec.md W1

## Context

`build.sh` compiled every Swift file with one `swiftc` call. `Package.swift` existed only for the tests and
covered `Sources/Core`. The AppKit files were in no target. SwiftPlantUML listed each Core type twice.
Sparkle was linked by hand-written `swiftc` flags.

## Decision

One package, two targets. `HijackCore` (`Sources/Core`) is the library the tests check. `Hijack`
(`Sources/App`) is the executable target; it depends on `HijackCore` and links Sparkle from
`.sparkle/<version>` through `unsafeFlags` (allowed on a root package). `build.sh` runs
`swift build -c release --product Hijack` and then assembles the bundle, embeds Sparkle and signs, as before.
`scripts/fetch-sparkle.sh` owns the pinned download, because `swift test` builds the app target too.

Core declarations that the app uses are `public`. `Plan`, `KeyInput`, `Deps` and `NamedKey` have explicit
public inits.

## Consequences

- A clean `make build` takes 26.9 s (43.1 s before): SwiftPM builds the two modules in parallel.
- The module boundary is now checked by the compiler: an app file that reaches into a non-public Core symbol
  does not compile.
- `swift test` needs the Sparkle framework present. `make test` fetches it first.
- The class diagram lists each type once.
- `.linkedFramework("Sparkle")` is not needed: `import Sparkle` autolinks the framework. The mutation script
  `scripts/mutate-build.sh` showed that entry was inert, so it is not in `Package.swift`.
