# 0025. Auto mode: pick hold or follow from the voice tool's version

- Topic: Voice tool integration
- Status: Accepted
- Date: 2026-10-19
- Evidence: ADR 0023, ADR 0024, docs/incidents/2026-10-04-echo-missing.md (2026-10-19 sections); WeType's updater log
  `~/Library/Caches/WeType/Logs/updater_20261016.log` (`previous=2.2.3(657), target=3.0.0(670)`)

## Context

ADR 0024 added follow mode for WeType 3.0, which takes a physical Fn itself and ignores a posted one. Hold mode,
the default, stopped working the day WeType 3.0.0 arrived (2026-10-17); 2.2.3 was the last version it worked with.
A user who installs Hijack, or whose WeType updates itself, gets a mode that does nothing until they find follow
mode in the menu. The owner asked for a default that works: Hijack knows the version the behaviour changed at.

## Decision

`triggerMode: "auto"` is the default (missing or unknown value). It resolves to follow when the selected voice tool
takes its own talk key, else hold. "Takes its own talk key" is a per-provider fact read from the tool's installed
version (`CFBundleShortVersionString` of its app bundle): WeType ≥ 3.0.0. Other tools: never, until a version is
known. An explicit hold / toggle / follow stays as set.

This is version sniffing, not feature detection, and that is a deliberate exception to the usual rule (MDN,
"Browser detection using the user agent string"): whether a key is swallowed can only be observed during a
dictation, by the `echo` / `ahead:` fields, not before it. The version decides up front; the dictation line
remains the evidence that the choice was right, and `hijack stats` keeps scoring it.

## Consequences

- Menu "How You Dictate" is a plain mode switch: Auto (now: Follow WeType) · Hold to Talk · Follow WeType · Tap to
  Start, Tap to Stop, with one small line under the switch saying what the effective mode does. Settings and
  `hijack status` show the resolved mode and the version that decided it.
- Every place that asked `triggerMode == "follow"` now asks the resolved mode (`Model.resolvedMode`,
  `SettingsStore.effectiveMode`); the raw value only marks which row is checked.
- The version is read from the bundle on each Model access (a plist read), never on the tap path.
- When WeType changes behaviour again, `DictationMode.weTypeTakesTalkKeyFrom` is the one line to change, with the
  incident evidence next to it.
