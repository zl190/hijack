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

`trigger: "follow"` follows the selected tool's voice key. `voiceKeys` stores overrides by source ID. `triggerMode` is `auto` (the default), `hold`, `toggle` or `follow`; `language` is `system`, `en` or `zh`. Logs are at `~/Library/Logs/Hijack.log`.

`triggerMode: "auto"` picks the mode from the installed voice tool's version: a tool that takes its own talk key and ignores keys sent by other apps (WeType from 3.0.0) gets follow mode, every other tool gets hold. The menu's Auto entry, Settings and `hijack status` show what it resolved to and which version decided it. Pick a mode by hand to override it.

`triggerMode: "follow"` is for a voice tool that starts itself on its own talk key (WeType 3.0 does, on a physical Fn, and ignores keys posted by another app). Hijack then never posts a key. It watches the system's input source: when it changes into the voice source and Hijack did not switch it, the tool has started, and Hijack goes back to the input source you came from once the tool's voice window closes or its microphone goes quiet. If the tool lets the talk key through, Hijack also sees the key; either way the trigger is the tool's talk key, and to use another physical key you remap it in a keyboard remapper such as Karabiner (`right_option → fn`). A switch to the voice source with no voice after it (⌃Space to type with it) is left alone.

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
hijack restart           # quit the running app and open it again
```

`status`, `sources`, `get`, and `stats` take `--json`.

In follow mode (`triggerMode: "follow"`) a dictation line reads `dictation … (follow): switched in by the tool, window closed 4337ms after start, back after 4.61s | mic tool on device off, window seen: 1 window` (the tool started itself; `mic off … after start` when it showed no window and its microphone ended the watch; `gave up, input source left in …` when it still read live after 60 s, where a switch would lose the text) or, when the tool let the talk key through, `dictation … (follow): held 2.9s, window closed 1627ms after release, back after 1.82s | …`: no `sent`, `echo` or `ahead:` field, since nothing was posted. `nothing live within 2.50s, input source left alone` is a switch to the voice source with no voice after it; a press shorter than `holdDelay` (a tap or a chord on the talk key) reads `released before fn was held for 0.20s`. Neither is judged (`hijack stats` counts the left-alone ones apart). A follow line whose text arrived but that did not switch back (`nothing to switch back to`, `gave up`) is scored `text arrived, input source not switched back` and counts against the success rate. `hijack stats` adds a `Follow mode` line (`followed` in `--json`) once any such line is in the period.

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

If dictation stops working and `hijack doctor` finds nothing, choose **Restart Hijack** in the menu (or run `hijack restart`). It quits the app and opens a fresh copy, the same thing Hijack does by itself after a dictation whose talk key never went out, but with no 10-minute limit. Each use leaves a `restart:` line in the log, and `hijack stats` counts them under Incidents as `manual restarts`.

If the log says `echo missing` and `ahead: WeType` (or another app's name), that app re-creates its key listener ahead of Hijack's and sees the talk key first; Hijack does not restart itself for this, because a fresh copy would sit behind it again within seconds. WeType 3.0 does this in its voice-input exclusive mode, and no user-facing switch for it was found: use follow mode (`hijack set mode follow`, above), where Hijack posts no key at all. `hijack doctor` prints the same warning while it is the case (and calls it harmless in follow mode), and `hijack stats` counts those dictations on its `Key listener` line.

If keys type the wrong thing after Hijack quits unexpectedly, a modifier key may be stuck down. Press and release your talk key once to clear it. Then open Hijack again. Hijack also tries to release a stuck key on its own the next time it starts.

If the `hijack` command is unavailable, run the app binary directly:

```sh
/Applications/Hijack.app/Contents/MacOS/Hijack doctor
```

[Report an issue](https://github.com/zl190/hijack/issues) with your macOS version, Hijack version, voice tool and steps to reproduce. Review logs before sharing them.
