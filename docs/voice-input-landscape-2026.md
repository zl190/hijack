# macOS 语音输入/听写工具全景（2025–2026）

调研目的：为 Hijack（github.com/zl190/hijack）判断哪些工具"语音功能仅在作为当前输入法时可用"（Hijack 适用），哪些已有全局热键（Hijack 不需要）。

## 1. 对比表

| 工具 | 类型 | 语音触发键 | 仅限"当前输入法激活"时可用？ | 平台/本地-云/价格 | 流行度信号（日期） |
|---|---|---|---|---|---|
| 微信输入法 WeType | IME | 长按 Fn（说完松手）；Fn+空格=免提模式 | 是（IME 架构决定） | macOS 原生版，云端识别，免费 | Mac 2.0 语音功能 2026-02~03 上线，社交媒体密集传播 [source: https://x.com/sagacity/status/2021093646532215191][source: https://blog.gudong.site/2026/02/11/weixin.html] |
| 搜狗输入法 Sogou | IME | 双击 Option 打开语音面板；2026-03-27 更新新增"按着说"（按住说话） | 是 | macOS 原生版，云端，识别率号称 98% | 更新日志标注 2026-03-27 [source: https://pinyin.sogou.com/mac/update_log.php] |
| 讯飞输入法 iFlytek | IME（但语音在独立窗口中） | 默认用 Fn，官方称**不可自定义**；识别文字需手动复制粘贴到目标 App，不能像普通 IME 直接连续录入 | 是，但体验割裂（非无缝转发） | macOS 原生版，云端，免费 | 用户评价下滑，有文章标题"错过了语音输入的新时代" [source: https://ft07.com/mac-voice-input-journey/][source: https://tianfei.chat/article/fly-input-missed-voice-input-era/] |
| 百度输入法 Baidu | IME | 未核实 | 未核实 | 据称支持 macOS/Win/iOS/Android，但一篇 2026 年对比文章里"语音输入"一栏标为空白 | 未核实（未找到 2025–2026 mac 语音专项报道）[source: https://www.cnblogs.com/wwkjs/p/19766002/zwsrf] |
| 豆包输入法 Doubao（字节跳动） | IME | 默认按住 Fn 说话 | 是 | 2026-05-13 macOS 版正式上线，云端，免费；宣称语音速度为"同类 AI 输入法 2-3 倍" | 上线即引发知乎/CSDN/博客密集测评 [source: https://www.appinn.com/doubao-shurufa-macos/][source: https://memoriblog.com/blog/2026-05-13-doubao-input-method-mac] |
| macOS 内置 Dictation | OS 内置 | Fn 键双击（或自定义快捷键），绑定到系统听写服务而非某个"输入法" | 否（跟随文本光标焦点，与"当前输入法"无关） | 原生，macOS Tahoe 起扩展离线/设备端识别、支持更长连续听写 | 系统自带，随 macOS 份额即为最大基数；Tahoe 26.1 修复了"F5 有声无字"问题 [source: https://www.yaps.ai/blog/macos-tahoe-dictation-review-2026] |
| Typeless | 独立 App（全局热键） | 自定义全局热键 | 否 | mac/Win/Linux/iOS/Android，云端 AI 整理（去口癖、格式化），支持 100+ 语言 | 2026-09 新增"Help me write"功能，常被列入对比评测 [source: https://www.yaps.ai/blog/typeless-alternative] |
| Wispr Flow | 独立 App（全局热键） | 自定义全局热键 | 否 | mac/Win/iOS/Android，云端，订阅制 | 2026 年 Series B 融资 2.8 亿美元，估值 20 亿美元；号称用户已用其写下 600 亿字，1 万+ 企业客户 [source: https://wisprflow.ai/post/series-b][source: https://en.wikipedia.org/wiki/Wispr_Flow] |
| Superwhisper | 独立 App（全局热键） | 默认 Option+Space，可自定义 | 否 | mac/Win/iOS，基于 Whisper，支持离线 | $8.49/月 或 $249.99 买断；大量 2026 对比评测文章 [source: https://superwhisper.com/docs/get-started/introduction][source: https://spokenly.app/blog/wispr-flow-vs-superwhisper-vs-macwhisper] |
| VoiceInk | 独立 App（全局热键），开源 Swift | 自定义全局热键 | 否 | mac 原生，whisper.cpp 本地识别，$25 一次性买断 | GitHub 5,099+ star（2026-05-27 记录）[source: https://github.com/Beingpax/VoiceInk][source: https://openalternative.co/voiceink] |
| MacWhisper | 独立 App（偏"文件转录"而非实时听写） | 热键可配置，但定位为音频文件转录工具 | 否 | mac 原生，本地识别，一次性约 €64 | 独立开发者 Jordi Bruin 出品，销量近 30 万份，Product Hunt 4.8–4.9/5（约 1,900 评价）[source: https://lumevoice.com/blog/macwhisper-review-2026/] |
| Aqua Voice | 独立 App（全局热键） | 自定义全局热键 | 否 | mac 原生，云端，97.3% 准确率宣称，前 1000 字免费后 $8/月，Max $24/月 | 9to5mac 2025-08-15 专文称赞 [source: https://9to5mac.com/2025/08/15/aqua-voice-shows-just-how-good-mac-dictation-could-be-if-apple-just-tried/] |
| Handy | 独立 App，开源（Tauri/Rust），全局热键 | 自定义全局热键 | 否 | mac/Win/Linux，完全离线，免费、无订阅、无字数上限 | GitHub 22,435 star（2026-05 记录），开源听写类项目中热度最高 [source: https://www.openassistivetech.org/handy-the-dictation-app-that-actually-respects-you/] |
| Openless（2026 新秀） | 独立 App，开源，全局热键 | 按住快捷键说话、松开即出润色文字 | 否 | macOS & Windows，AI 润色 | GitHub 新项目，2026 年出现 [source: https://github.com/Open-Less/openless] |

## 2. Hijack 适用清单

以下工具是"作为输入法（active input source）时，语音键才生效"的典型场景——Hijack 的切入点正是这类工具：

- **微信输入法 WeType**：语音键 = 长按 `Fn`（松手结束）或 `Fn+空格`（免提）。
- **搜狗输入法 Sogou**：语音键 = 双击 `Option`，或 2026-03 新增的"按着说"（按住说话）。
- **讯飞输入法 iFlytek**：语音键 = `Fn`（官方称不可改），但其语音在独立窗口中识别，文字需手动复制粘贴，不是无缝转发到目标 App——Hijack 若要支持它，还要解决"取字"这一步，不只是切换+转发按键。
- **豆包输入法 Doubao**：语音键 = 默认按住 `Fn`。
- **百度输入法 Baidu**：是否有同类限制未核实，暂不纳入。

**不需要 Hijack**：macOS 内置 Dictation（跟随文本光标而非"当前输入法"）、Typeless、Wispr Flow、Superwhisper、VoiceInk、MacWhisper、Aqua Voice、Handy、Openless ——它们都已有独立于输入法切换的全局热键。

## 3. 流行度 Top 3

**中国区**：
1. 微信输入法 WeType——依托微信庞大装机基础，2026 年初 Mac 2.0 语音功能上线后社交媒体（X/知乎/博客）大量自发传播 [source: https://x.com/sagacity/status/2021093646532215191]。
2. 搜狗输入法 Sogou——老牌主流中文 IME，持续迭代语音能力（"按着说"2026-03-27）[source: https://pinyin.sogou.com/mac/update_log.php]。
3. 豆包输入法 Doubao——字节系背书，2026-05-13 mac 版上线即引发密集测评，被称"10 年没换过输入法的人半年换了 3 次"[source: https://www.jxxy.net/ai/articles/sitinme-2054732435531964852/]。（讯飞因交互割裂口碑下滑，未入前三。）

**全球区**：
1. Wispr Flow——2026 年 Series B 2.8 亿美元融资、估值 20 亿美元，60 亿+ 字、1 万+ 企业客户 [source: https://wisprflow.ai/post/series-b]。
2. Handy——开源听写类目中 GitHub star 最高（22,435，2026-05）[source: https://www.openassistivetech.org/handy-the-dictation-app-that-actually-respects-you/]。
3. Superwhisper / MacWhisper 并列——Superwhisper 在几乎所有 2026 对比评测中被列为标杆；MacWhisper 销量近 30 万份、Product Hunt 近 1,900 条 4.8 分好评 [source: https://lumevoice.com/blog/macwhisper-review-2026/]。

## 4. 未核实 / 空白

- 百度输入法 macOS 语音输入的按键方式、是否"仅限激活态"、是否已上线，均未找到直接信源。
- 讯飞输入法 2026 最新版是否仍"按键不可改"、是否已解决复制粘贴割裂问题，未找到最新（2026 下半年）更新说明。
- Wispr Flow / Aqua Voice 的具体订阅价格分档、是否支持中国区支付，未核实。
- 各中文 IME（WeType/Sogou/Doubao）官方未公布 mac 端具体下载量/MAU，流行度判断依赖社交媒体声量与媒体报道，非官方统计数字。

## Hijack 实测（2026-10-01，macOS 27）

| 工具 | 方式 | 结果 |
|---|---|---|
| 微信输入法 6.x | 切过去 + 转发语音键（右 Option 或 Fn 都测过） | ✅ 无缝上屏；语音键从它的 MMKV 设置自动读取 |
| 豆包输入法 1.0.1 | 切过去 + 转发 Fn | ✅ 无缝上屏；语音键读不到，用内置默认值 Fn |
| 搜狗输入法 6.25.1 | 切过去 + 转发左 Option（按住） | ⚠️ 能触发，但结果在单独的语音助手窗口（`com.sogou.voiceassistant`），焦点会落到那里，要手动复制；更新日志里「按着说」在本机版本找不到 |
| Handy 0.9.7 | 不切输入法，替用户按 ⌥Space | ✅ 可用；热键从它的 settings_store.json 自动读取；与 Hijack 并存无冲突 |

注：上面的「Handy GitHub 22,435 star」已过时，2026-10-01 实测 32,504。
