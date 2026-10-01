# Hijack

Hold a key to dictate with WeType (微信输入法) from any input source; your previous input source comes back when you're done.

按住一个键，用微信输入法说话；说完自动切回原来的输入法。

## Install

Apple silicon, macOS 13+, and WeType with its push-to-talk voice key set.

```sh
curl -fsSL https://raw.githubusercontent.com/zl190/hijack/main/install.sh | sh
```

or

```sh
brew install --cask zl190/tap/hijack
```

Then allow Hijack in System Settings › Privacy & Security › Accessibility (once; updates keep it).

Build from source instead: `./install-from-source.sh` (needs Xcode Command Line Tools).

## Settings

The menu bar icon (or opening Hijack again) has quick picks for the common settings; **⌘,** in the menu opens the full config file:

`~/.config/hijack/config.json`

```json
{
  "trigger": "follow",
  "voiceInput": "com.tencent.inputmethod.wetype.pinyin",
  "voiceKey": "auto",
  "showMenuBarIcon": true,
  "language": "system",
  "holdDelay": 0.2,
  "restoreTimeout": 5,
  "fallbackDelay": 2.5
}
```

- `trigger`: the key you hold. `"follow"` = same as the voice key.
- `voiceKey`: the voice input method's own push-to-talk key. `"auto"` = read it from WeType.
- Keys: a name (`right_option`, `left_option`, `right_command`, `left_command`, `right_control`, `left_control`, `right_shift`, `left_shift`, `fn`, `f13`–`f20`, `space`) or `{"keyCode": 79, "modifiers": ["ctrl", "option"]}` (modifiers: `ctrl`, `option`, `shift`, `command`, `fn`).
- `voiceInput`: input source ID of the voice input method (WeType by default).
- `language`: `system`, `en`, or `zh`.

Edits apply on the next key press; no restart. Logs: `~/Library/Logs/Hijack.log`.

## License

MIT
