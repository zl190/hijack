# Settings 窗口 SOTA(2025–2026)· 给 Hijack 的调研

## 1. HIG / macOS 26 Tahoe

- SwiftUI `Settings` scene 仍是官方推荐入口,但对 **accessory app(LSUIElement / `.accessory` activation policy)有已知坑**:`SettingsLink`/`openSettings()` 不会激活 app,窗口常开在别的 app 后面,二次打开仍在后面。解法:在打开前手动 `NSApp.activate(ignoringOtherApps: true)`,或临时切 `.regular` 再切回 `.accessory` [source: https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items, 2025]。GitHub issue 实锤同一问题 [source: https://github.com/joaodavidsilva/brightboi/issues/78]。
- Tahoe 26 引入 **Liquid Glass**:系统设置自身是 `NavigationSplitView`(侧栏+详情),玻璃窗口 chrome(圆角、半透明侧栏、模糊标题栏)需要在创建窗口时设 `.fullSizeContentView`;分组用 `Form` + 透明背景 + 滚动边缘效果 [source: https://www.skills.sh/fayazara/macos-app-skills/macos-settings-ui, 2025/2026]。
- macOS 对 Tab 的新默认是 `sidebarAdaptable`:iOS/watchOS 用 Tab,macOS/iPadOS 自动变侧栏 [source: https://developer.apple.com/videos/play/wwdc2025/323/, WWDC25]。但这是给**内容型** App(多数据域)设计的;小工具类设置页仍普遍用传统 `TabView`(见下节案例)。
- 未核实:官方是否对"小型菜单栏工具"专门给出"该用 Tab 还是 Sidebar"的体量阈值建议——HIG 文本本身没有按窗口大小分层的明确规则,这是从案例反推的经验。

## 2. 同类菜单栏工具的设置页结构(2025–2026 实践)

- **Ice**(开源菜单栏管理器,26K★,纯 SwiftUI):偏好存 `UserDefaults`,窗口走传统分区(General/Menu Bar Layout/Hotkeys/Appearance 等)而非侧栏 [source: https://github.com/cavaldos/Ice, 2025–2026 fork 页面汇总]。
- **CleanShot X**:`Cmd+,` 打开偏好,**顶部 Tab 分区**(General / Screenshots / Video / GIF / Shortcuts 等),Shortcuts 单独一个 tab 做快捷键编辑,录屏参数拆 General/Video/GIF 三块 [source: https://cleanshot.com/changelog; https://keyscreen.app/cleanshot-x-keyboard-shortcuts, 2025]。
- **Raycast**:v2 把 Settings 重新设计成"单一、简洁界面",顶部按功能分区(Launcher/AI/Extensions 等);权限按需请求——**第一次用某个命令时才弹 Accessibility 授权引导**,不是启动即弹 [source: https://manual.raycast.com/settings; https://developers.raycast.com/information/security, 2025]。
- **VoiceInk**(开源,Superwhisper/Wispr Flow 的开源替代):全局快捷键可配置(键盘或鼠标),含 push-to-talk 与语音助手模式;重编译后常因系统权限重置导致快捷键"静默失效",需要重新手动到 System Settings 授权 Accessibility/Input Monitoring——这是一个值得 Hijack 警惕的真实坑(权限状态要实时刷新显示,不能缓存旧状态)[source: https://github.com/Beingpax/VoiceInk; BUILDING.md 提及的权限重授权问题, 2025–2026]。
- 未直接取得 Rectangle Pro / Bartender / Maccy / Superwhisper / Wispr Flow / Hand Mirror / Klack 的设置页实测细节(本轮搜索未命中够具体的一手资料),标记"未核实"。

## 3. 快捷键录制组件

- **sindresorhus/KeyboardShortcuts**:业界最常被复用的录制组件,但**原生不支持纯修饰键**(modifier-only)快捷键——Apple 在 macOS 15.0/15.1 一度因"安全原因"限制纯 Option / Option+Shift 快捷键,库里 v2.1.0 曾放开,v2.2.4 又因 15.2 的系统行为改回限制;Caps Lock 作为修饰键也无法用标准事件监听 [source: https://github.com/sindresorhus/KeyboardShortcuts/issues; releases 页面, 2025]。**这证实了 Hijack 不能直接 fork 这个库来做 Fn / Right Option 类需求。**
- **Input Source Pro**(开源,输入法切换工具):v2.8.0 专门加了"单修饰键"快捷方式,支持 **左右 Shift/Control/Option/Command 区分** + 单击/双击触发;v2.9.0 再加多修饰键组合(如 Shift+Command)[source: https://inputsource.pro/changelog, 2025]。这是目前能找到的、**唯一明确做了"左右区分 + 纯修饰键"录制 UX** 的开源参照,Hijack 的 Right Option / Fn 需求应直接借鉴它的实现路径(CGEventTap 监听 flagsChanged,区分 `kVK_RightOption` 等 keycode,而非走 Carbon hotkey API,因为后者不支持纯修饰键)。
- VoiceInk 的录制器未查到源码级细节(本轮未深入读 `.swift` 文件),标记"未核实,需要读源码确认它是否支持修饰键单键"。
- 通用 UX 模式(从 CleanShot/行业惯例汇总,非单一引用):点击录制框 → 文案变成"Press keys…" → 按键后文字框内回显按键组合 → 框右侧出现"×"清除按钮 → 若与系统或其他动作冲突则在框下方出现黄色/红色警告文案。这是本调研里的综合判断,非单一来源直证,标记"部分未核实"。

## 4. 权限 UX(Accessibility)

- **"Drag to grant"** 模式正在成为事实标准:缺权限时,app 打开系统的 Accessibility 面板,同时自己弹一个引导浮层("把 App 拖进列表"),macOS 上报授权后自动关闭引导、关闭刚打开的 Settings 窗口、恢复正常功能 [source: 综合自 GitHub issue 讨论(filipmares/tile #22、rezaahmadn/TrayFold PR #1), 2025–2026]。
- 必须**实时监听权限变化**而非只在启动时查一次——通过 `com.apple.accessibility.api` 的分布式通知或轮询 `AXIsProcessTrusted()`,菜单/设置页里对应的状态文案要跟着变 [source: 同上 issue 讨论]。
- 未查到 sindresorhus 本人维护的专门 "PermissionFlow" 包——该命名可能是推测性的,未核实其是否存在;实际常见做法是各 app 自己包一层 `AXIsProcessTrustedWithOptions` + 打开 `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`。

## 5. 配置文件双向同步("设置 UI + 纯文本配置")

- **Ghostty**:配置文件在 `~/Library/Application Support/com.mitchellh.ghostty/config`,**监听文件变化并立即应用**,无需重启或手动 reload;也可用 `cmd+shift+,` 主动触发 reload action [source: https://ghostty.org/docs/config, 2025–2026]。已知 bug:遇到非法 key-value 并点击"忽略"后,之后的改动会**再也不被 reload**,维护者称新版本可能已修复但未完全确认 [source: https://github.com/ghostty-org/ghostty/discussions/3772, 2025]——这是 Hijack 必须避免的反面案例:错误处理路径不能让"忽略一次"变成"永久停止监听"。
- **Karabiner-Elements**:`complex_modifications` 规则是纯 JSON(`~/.config/karabiner/assets/complex_modifications`),GUI 里"Add rule"直接读取该目录下的 JSON 文件;社区衍生出 Web UI 生成器和 `karabiner.ts`(TypeScript→JSON)来避免手搓 JSON 出错 [source: https://karabiner-elements.pqrs.org/docs/json/external-json-generators/, 持续维护]。它的模式对 Hijack 有参考价值:**JSON 文件是唯一真源,GUI 只是读写该文件的一个视图**,手改文件后重启/reload GUI 即生效。
- Aerospace / Hammerspoon 这轮未取得具体的一手资料(常识性了解:两者都是"启动时读 + 文件变化触发 reload",但未核实到 2025–2026 的具体实现细节),标记"未核实"。

## 对比表

| App | 结构 | 权限 UX | 录制器 | 配置文件 |
|---|---|---|---|---|
| Ice | 多 Tab(General/Menu Bar Layout/Hotkeys/Appearance) | 未查到细节(未核实) | 标准 KeyboardShortcuts 类库(推测,未核实) | UserDefaults,非纯文本 |
| CleanShot X | 顶部 Tab(General/Screenshots/Video/GIF/Shortcuts) | 未查到细节(未核实) | 自研,Shortcuts 独立 tab | 未知(未核实) |
| Raycast | 单页多分区(非传统 tab 栅格,更像功能区块) | 按需请求,首次用命令才弹权限引导 | 自研全局热键录制 | 内部存储,非用户可编辑文本文件 |
| VoiceInk(开源) | 未细查(未核实) | 需手动在 System Settings 授权,重编译后常需重授权 | 支持键盘/鼠标快捷键 + push-to-talk,源码级细节未核实 | 未核实 |
| Input Source Pro(开源) | 未细查(未核实) | 未核实 | **左右修饰键区分 + 单击/双击触发**,行业内目前最接近 Hijack 需求的实现 | 未核实 |
| Ghostty | 无设置窗口,纯配置文件 + CLI | N/A | N/A | **文件监听自动 reload**,非法值处理有已知 bug(忽略后停止监听) |
| Karabiner-Elements | GUI 多 Tab,背后读写 JSON | 需要 Input Monitoring 等权限(未细查 UX) | 不适用(复杂规则非单键) | **JSON 为唯一真源**,GUI 是其视图,社区有 TS/Web 生成器避免手改出错 |

## Hijack 应该学的(≤8 条,带立场)

1. **单页 + 顶部 Tab,不上侧栏。** Hijack 的设置项(触发模式/快捷键/dictation sources 列表/权限/启动项/外观/高级/测试区)量级接近 CleanShot X 而非 System Settings 级的多域应用;`NavigationSplitView` 侧栏对这个体量是过度设计,传统 `TabView`(或 SwiftUI `Settings` 的 tabbed 风格)更合适,窗口宽度建议 480–600pt,仿 CleanShot/Ice 的紧凑分区。
2. **"Try it" 测试区放在触发模式/快捷键 tab 内,不单独开 tab。** 测试区的价值是"改完立刻验证",离配置项越近越好;做成该 tab 底部一个常驻的小面板(类似 CleanShot 录屏参数旁的实时预览),而不是逼用户跳转。
3. **录制器必须自研(照抄 Input Source Pro 的思路),不要直接用 KeyboardShortcuts 包。** 该库官方不支持纯修饰键且曾被系统策略反复打脸;Hijack 需要 CGEventTap 监听 `flagsChanged` + 区分左右 keycode(`kVK_RightOption`/`kVK_Function`等),这是 ⌃⌥F18、Right Option、Fn 场景的硬需求。
4. **录制 UX 按行业惯例实现:点击 → "Press keys…" 占位文案 → 实时回显 → 清除按钮 → 冲突时下方警告文案**(与系统全局快捷键或其他 dictation source 冲突都要检测,因为 Hijack 本身就有"多个 source 各自一个 key"的冲突风险)。
5. **Accessibility 权限用"打开系统面板 + 自绘拖拽引导浮层 + 轮询/监听状态自动关闭引导"的三段式**,并且设置窗口里的权限状态要订阅式刷新,不能只在窗口打开那一刻查一次——VoiceInk 的"权限静默失效"教训要当反例写进测试清单。
6. **config.json 是唯一真源,设置窗口是只写入+重新读取的视图,不维护内存态副本长期漂移。** 参照 Karabiner 的模式:UI 改动 → 立即写文件;文件被手改 → 文件系统事件(FSEventStream / DispatchSource)触发重新读取并刷新 UI。避免 Ghostty 那个"忽略一次非法值后永久停止监听"的 bug:**解析失败要继续监听,只是本次改动不生效并在 UI 顶部给出持久的小红条,而不是进入"已放弃监听"的隐藏状态**。
7. **菜单栏 app 打开设置窗口前必须先 `NSApp.activate(ignoringOtherApps: true)`**,否则会复现 SettingsLink/openSettings 在 accessory app 下"开在别的窗口后面"的已知坑;Hijack 现在用自定义窗口而非 SwiftUI `Settings` scene 更安全,但激活逻辑仍要显式写,别依赖默认行为。
8. **Liquid Glass 可以晚做。** Tahoe 的玻璃材质/`.fullSizeContentView` 是视觉加分项,不是功能阻塞项;先把 Tab/Form(`.formStyle(.grouped)`)+ 功能跑通,玻璃化留到 polish 阶段单独一个 PR,避免把窗口 chrome 的坑和功能坑混在一起调试。

## 未核实

- Rectangle / Rectangle Pro、Bartender、Maccy、Superwhisper、Wispr Flow、Hand Mirror、Klack 的设置页结构/权限 UX/配置导入导出——本轮搜索未命中足够具体的一手资料(官网/仓库/2025-2026 文章),需要单独针对每个产品再查一轮或直接装 app 实测。
- "PermissionFlow"(题目里提到的 sindresorhus 包)是否真实存在——未查到对应仓库,可能是记忆误差或非 sindresorhus 作品。
- Aerospace、Hammerspoon 的配置文件双向同步细节——仅凭背景知识带过,未取得 2025–2026 的一手验证。
- VoiceInk / Input Source Pro 录制器的具体源码实现(是否真用 CGEventTap、是否处理了 Fn 键的特殊事件类型)——仅从 changelog/issue 层面推断,未读源码确认。
- Apple HIG 是否对"菜单栏小工具该用 Tab 还是 Sidebar"给出按窗口体量分层的官方文字规则——未找到此类明确表述,第 1 条的 Tab 建议是从案例反推,非官方文档直证。
