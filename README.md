<picture>
  <source media="(prefers-color-scheme: dark)" srcset="site/assets/brand/hijack-wordmark-inverse.svg">
  <img src="site/assets/brand/hijack-wordmark.svg" width="190" alt="Hijack">
</picture>

Voice input, then back to your preferred input method.

语音输入，然后切回原来的输入法。

[![Latest release](https://img.shields.io/github/v/release/zl190/hijack?color=626e56)](https://github.com/zl190/hijack/releases/latest)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-626e56?logo=apple&logoColor=white)](#install)
[![License: MIT](https://img.shields.io/github/license/zl190/hijack?color=626e56)](LICENSE)
[![Website](https://img.shields.io/badge/website-hijack.ylab3.com-a44830)](https://hijack.ylab3.com)

## Install

Apple silicon, macOS 13+, and an installed voice input tool.

```sh
curl -fsSL https://raw.githubusercontent.com/zl190/hijack/main/install.sh | sh
```

or

```sh
brew install --cask zl190/tap/hijack
```

Allow Hijack in System Settings › Privacy & Security › Accessibility. Open Hijack to choose your voice tool and trigger key in Settings. Hold to talk, or choose hands-free mode to tap to start and stop.

Build from source: `./install-from-source.sh` (requires Xcode Command Line Tools).

## Voice tools

| Type | Tool | Status |
| --- | --- | --- |
| Input method | WeType · 微信输入法 | Tested |
| Input method | Sogou · 搜狗输入法 | Tested |
| Input method | Doubao · 豆包输入法 | Tested |
| App | Handy | Tested |
| App | Wispr Flow | Supported; testing pending |
| App | Openless | Supported; testing pending |
| App | Typeless | Supported; testing pending |

Compatibility status is reported by the project owner as of 2026-10-01. Version 1.1 includes built-in providers for WeType, Sogou, Doubao and Handy. Other apps use manual voice-key configuration; their end-to-end behavior still needs validation. For input-method providers, Hijack restores the previous input source after dictation. Standalone app providers do not need to change the input source.

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

`hijack` is the same app run from the terminal (Homebrew puts it on your PATH; the install scripts link it into `~/.local/bin`):

```sh
hijack status            # what Hijack is doing, and whether it can
hijack doctor            # check everything; exits 1 if something is broken
hijack sources           # installed voice sources and their talk keys
hijack get [setting]     # read settings
hijack set mode toggle   # change a setting (validated)
hijack log -f            # follow the log
```

`status`, `sources`, and `get` take `--json`.

## Website and brand

The bilingual homepage is served at [hijack.ylab3.com](https://hijack.ylab3.com) by Cloudflare Workers Static Assets. [apps.ylab3.com](https://apps.ylab3.com) lists the app. Website source and local preview instructions are in [`site/`](site/README.md); reusable wordmarks and usage notes are in [`site/assets/brand/`](site/assets/brand/README.md).

```sh
npm ci
npm run check
npm run deploy:cf
```

## License

MIT. Third-party homepage imagery has separate provenance documented in [`site/README.md`](site/README.md).
