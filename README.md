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

Click the menu bar icon (or open Hijack again if the icon is hidden): trigger key, launch at login, menu bar icon, language.

The trigger key follows WeType's voice key by default.

Other voice input sources (unmaintained): `defaults write com.zl190.hijack voiceInputSource <id>`

## License

MIT
