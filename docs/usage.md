# Using Hijack

[Installation and quick start](../README.md#install)

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
```

`status`, `sources`, and `get` take `--json`.

## Troubleshooting

If the trigger does nothing, confirm that Hijack has Accessibility permission and that your selected voice tool works on its own. Run `hijack doctor` to check permissions, configuration and voice-source availability.

If keys type the wrong thing after Hijack quits unexpectedly, a modifier key may be stuck down. Press and release your talk key once to clear it. Then open Hijack again. Hijack also tries to release a stuck key on its own the next time it starts.

If the `hijack` command is unavailable, run the app binary directly:

```sh
/Applications/Hijack.app/Contents/MacOS/Hijack doctor
```

[Report an issue](https://github.com/zl190/hijack/issues) with your macOS version, Hijack version, voice tool and steps to reproduce. Review logs before sharing them.
