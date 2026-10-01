# ime-voice

按住右 Option，用微信输入法（WeType）语音输入；松开后切回原来的输入法。

## 安装

需要 [Karabiner-Elements](https://karabiner-elements.pqrs.org/)、微信输入法（语音快捷键设为按住右 Option）、Xcode Command Line Tools。

```sh
git clone https://github.com/zl190/ime-voice.git
cd ime-voice && ./install.sh
```

Karabiner-Elements → Complex Modifications → Add predefined rule → ime-voice → Enable。

## 调整

`karabiner-rule.json`：

- `basic.to_if_held_down_threshold_milliseconds`：按住多久开始录音（默认 200）
- `ime-voice end 2.5`：松开后几秒切回

其他输入法：`ime-voice begin <输入源 ID>`（不维护）。

## License

MIT
