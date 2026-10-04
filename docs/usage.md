# Using Hijack

[Installation and quick start](../README.md#install). The install script checks the download's
checksum and signature before it touches `/Applications`.

## Settings

Open Hijack again, or choose **Settings… (⌘,)** in its menu. The Dictation, Sources, General and Advanced tabs cover the trigger, voice tools, language, icons and timing.

The source of truth is `~/.config/hijack/config.json`. Edits apply on the next key press; no restart is needed. An invalid JSON file is never overwritten. Example:

```json
{
  "trigger": "follow",
  "voiceInput": "com.tencent.inputmethod.wetype.pinyin",
  "voiceKeys": {},
  "triggerMode": "hold",
  "stopOnAnyKey": true,
  "language": "system"
}
```

`trigger: "follow"` follows the selected tool's voice key. `voiceKeys` stores overrides by source ID. `triggerMode` is `hold` or `toggle`; `language` is `system`, `en` or `zh`. Logs are at `~/Library/Logs/Hijack.log`.

## Command line

`hijack` is the same app run from the terminal (Homebrew puts it on your PATH; the install scripts also create a link when `~/.local/bin` exists and is on your PATH):

```sh
hijack status            # what Hijack is doing, and whether it can
hijack doctor            # check everything; exits 1 if something is broken
hijack sources           # installed voice sources and their talk keys
hijack get [setting]     # read settings
hijack set mode toggle   # change a setting (validated)
hijack log -f            # follow the log
hijack stats             # how reliable dictation has been (default: last 7 days)
```

`status`, `sources`, `get`, and `stats` take `--json`.

`hijack stats` prints a `target` line under the success rate: `success >= 99.0%` is the current
reliability bar (`Sources/Core/Stats.swift`'s `successTarget`, provisional until 7 days of 1.2.x data),
next to this period's own rate and `met` or `not met`. `--json` carries the same two values as `target`
and `met`. Neither appears before any dictation has been judged (text arrived, or no voice window seen).

## System health (MetricKit)

macOS sends Hijack a report about once a day. The report holds CPU time, memory use, hangs and crashes. Hijack writes each report to `~/Library/Logs/Hijack-metrics`. It keeps the newest 30 files.

Run `hijack stats` to see the "System (MetricKit)" block: hang count and longest hang, crash count and last crash date, CPU time per day, and peak memory. The block is empty on a new install. Wait about a day for the first report. `hijack doctor` warns when a crash report is newer than the app's last start.

Hang count, crash count and the last crash date come straight from the report. The longest hang, CPU time and peak memory are read against the documented field names, but not yet checked against a real report (none has arrived on a development Mac yet). If Hijack cannot read one of those three, it prints `n/a (unrecognized format)` in its place, never a 0 it did not actually measure. `--json` counts every such case in `parseWarnings`.

## Updates

Hijack checks for a new version once a day and asks before it installs one. "Check for Updates…" in the menu runs a check now. Settings › General › Updates has two switches: automatic checks, and automatic download and install. `hijack version` prints the running version and the version the last check found. Homebrew users can keep using `brew upgrade`; both paths replace the same app.

## Troubleshooting

If the trigger does nothing, confirm that Hijack has Accessibility permission and that your selected voice tool works on its own. Run `hijack doctor` to check permissions, configuration and voice-source availability.

If keys type the wrong thing after Hijack quits unexpectedly, a modifier key may be stuck down. Press and release your talk key once to clear it. Then open Hijack again. Hijack also tries to release a stuck key on its own the next time it starts.

If the `hijack` command is unavailable, run the app binary directly:

```sh
/Applications/Hijack.app/Contents/MacOS/Hijack doctor
```

[Report an issue](https://github.com/zl190/hijack/issues) with your macOS version, Hijack version, voice tool and steps to reproduce. Review logs before sharing them.
