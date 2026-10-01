# Hijack

Hold a key to dictate with WeType (微信输入法) from any input source; your previous input source comes back when you're done.

按住一个键，用微信输入法说话；说完自动切回原来的输入法。

## Install

Needs Xcode Command Line Tools and WeType with its push-to-talk voice key set.

```sh
git clone https://github.com/zl190/hijack.git
cd hijack && ./install.sh
```

Allow Hijack in System Settings › Privacy & Security › Accessibility.

## Settings

Click the menu bar icon (or open Hijack again if the icon is hidden): trigger key, launch at login, menu bar icon, language.

The trigger key follows WeType's voice key by default.

Other voice input sources (unmaintained): `defaults write com.zl190.hijack voiceInputSource <id>`

## License

MIT
