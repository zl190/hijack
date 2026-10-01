#!/bin/sh
# Build ime-voice and install the Karabiner rule. Needs Xcode Command Line Tools (xcode-select --install).
set -e
cd "$(dirname "$0")"
mkdir -p "$HOME/.local/bin" "$HOME/.config/karabiner/assets/complex_modifications"
swiftc -O ime-voice.swift -o "$HOME/.local/bin/ime-voice"
cp karabiner-rule.json "$HOME/.config/karabiner/assets/complex_modifications/ime-voice.json"
echo "Installed ~/.local/bin/ime-voice"
echo "Next: Karabiner-Elements > Complex Modifications > Add predefined rule > ime-voice > Enable"
