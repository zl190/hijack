<img src="assets/hijack-wordmark-readme.svg" width="210" alt="Hijack">

**Voice input, then back to your preferred input method.**

Hijack is a small macOS menu bar app that connects your trigger key to a voice input tool. Dictate with WeType, Sogou or Doubao, then return to the input method you were using. Standalone apps such as Handy work without switching input methods.

[![ci](https://img.shields.io/github/actions/workflow/status/zl190/hijack/ci.yml?branch=main&style=flat-square&label=ci)](https://github.com/zl190/hijack/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/zl190/hijack?style=flat-square&label=release&color=blue)](https://github.com/zl190/hijack/releases/latest)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?style=flat-square&logo=apple&logoColor=white)](#install)
[![License: MIT](https://img.shields.io/github/license/zl190/hijack?style=flat-square&color=green)](LICENSE)

[See it in action](https://hijack.ylab3.com/?lang=en) · [User guide](docs/usage.md) · [Report an issue](https://github.com/zl190/hijack/issues)

## Install

Requires **Apple silicon**, **macOS 13 or later**, and a voice input tool installed separately.

```sh
brew install --cask zl190/tap/hijack
```

Or install the latest release with:

```sh
curl -fsSL https://raw.githubusercontent.com/zl190/hijack/main/install.sh | sh
```

## Get started

1. Open Hijack and allow it in **System Settings → Privacy & Security → Accessibility**.
2. In Hijack's **Settings**, choose your voice tool and trigger key.
3. Hold the trigger to talk, then release it. After your voice tool submits the text, Hijack restores your previous input method.

Prefer hands-free dictation? Choose toggle mode to tap once to start and again to stop.

## Voice tools

| Tool | Integration | Status |
| --- | --- | --- |
| WeType | Input method | Tested |
| Sogou | Input method | Tested |
| Doubao | Input method | Tested |
| Handy | Standalone app | Tested |
| Wispr Flow | Manual voice-key configuration | Testing pending |
| Openless | Manual voice-key configuration | Testing pending |
| Typeless | Manual voice-key configuration | Testing pending |

Compatibility reflects maintainer testing as of October 1, 2026. The first four tools have built-in providers; the remaining apps use manual configuration and still need end-to-end validation.

## Help and development

See the [user guide](docs/usage.md) for settings, command-line usage and troubleshooting. Download updates and read changes on the [releases page](https://github.com/zl190/hijack/releases).

To build from a local checkout, run `make install` with Xcode Command Line Tools installed.

## License

[MIT](LICENSE).
