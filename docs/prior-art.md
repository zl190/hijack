# Prior art：输入法切换 + modifier-only push-to-talk

## 1. runjuu/InputSourcePro

**CJKV bug 绕过**：`InputSourceSwitcher.swift` 里 `switchToTarget` 对 CJKV 输入法（语言前缀 `zh`/`ko`/`ja`/`vi`）启用 `CJKVFixStrategy`，两种实现：
- `.temporaryInputWindow`：`TISSelectInputSource` 后立刻 `showTemporaryInputWindow()` 弹一个 3x3px、几乎透明（`alphaValue=0.01`）、`level=.screenSaver` 的无边框窗口并 `makeKeyAndOrderFront`+`NSApp.activate`，80ms 后关闭并把前台应用切回原 app；80+50ms 后再读一次 `getCurrentInputSource()`，不匹配就重发 `TISSelectInputSource` 兜底 [source: github.com/runjuu/InputSourcePro/blob/main/Input%20Source%20Pro/Utilities/InputSource/InputSourceSwitcher.swift#L170-L205]。注释明确写明此法 "Adapted from macism's showTemporaryInputWindow approach"。
- `.previousInputSourceShortcut`：选目标源→选一个非 CJKV 源"反弹"→100ms 后用 CGEvent 回放系统"前一个输入法"快捷键（从 `com.apple.symbolichotkeys` plist 读 keyCode+modifier）把源切回去，事件打上 `eventSourceUserData = "ISPCSJKV"` 标记为合成事件，并设置 `syntheticEventEndTime`（~350ms）让自家的 `ShortcutTriggerManager` 在这段时间内忽略 flagsChanged，避免合成按键污染 modifier 状态机 [source: .../InputSourceSwitcher.swift#L207-L240, #L310-L345]。

**热键库**：`ShortcutTrigger.swift` 对普通组合键用 `sindresorhus/KeyboardShortcuts`（`KeyboardShortcuts.onKeyUp`），但对 "Modifier Combination"（含单个 modifier，如 Right Option 单键）**完全绕开该库**，自建 `ShortcutTriggerManager`：`NSEvent.addGlobalMonitorForEvents(.flagsChanged)` 做跨 app 监听 + 一个 `.cgSessionEventTap`/`headInsert`/`.listenOnly` 的 CGEventTap 监听 keyDown/mouseDown/scroll 用于"按下其它键则作废本次 modifier 组合"[source: .../Utilities/ShortcutTrigger.swift#L267-L330]。即 KeyboardShortcuts 不支持 modifier-only，InputSourcePro 用自写状态机补齐，并且双重去重（时间戳+keyCode）防止 global/local monitor 重复触发。

**Launch at login / 菜单栏**：用 `LaunchAtLogin`（`LaunchAtLogin.migrateIfNeeded()`）第三方库，`AppDelegate.swift` 里 `statusItemController`、`indicatorWindowController` 分离状态栏图标与浮层指示器两个控制器 [source: .../System/AppDelegate.swift#L1-L70]。App 名/图标走标准 `Resources/Assets.xcassets/AppIcon.appiconset`，无特殊之处。

## 2. laishulu/macism

**Bug 机制**：TISSelectInputSource 对 CJKV 源会"在菜单栏图标已变但实际没生效"，直到切到别的 app 再切回来才生效——这是 README 明确描述的已知坑 [source: github.com/laishulu/macism/blob/master/README.md]。

**绕过机制**：`InputSource.select()`（`InputSourceManager.swift#L36-L46`）里，非 CJKV 源直接 `TISSelectInputSource`；CJKV 源则调用之后紧跟 `showTemporaryInputWindow(waitTimeMs:)`（定义于 `WindowUtils.swift`）：创建一个真实的 `.titled` style、`level=.screenSaver`、紫色背景窗口，`app.activate(ignoringOtherApps:true)` 抢焦点，`DispatchQueue.main.asyncAfter` 等待（默认 150ms，可用 `MACISM_WAIT_TIME_MS` 环境变量覆盖）后 `app.terminate(nil)` 并 `app.run()` 阻塞等待 [source: github.com/laishulu/macism/blob/master/WindowUtils.swift#L25-L55]。本质：**让一个新窗口真正获得键盘焦点，逼 TIS 把输入法切换"坐实"**，然后立刻销毁。InputSourcePro 的 temporaryInputWindow 策略就是从这里改造来的（更轻量：3x3px 几乎透明窗口代替真实紫色窗口，不新建进程）。

## 3. Push-to-talk / modifier-only 绑定：Handy 与 VoiceInk

**VoiceInk**（Swift/AppKit）：`ShortcutMonitor.swift` 用单个 `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, ...)`（非 `.listenOnly`，可吞事件）监听 `keyDown/keyUp/flagsChanged/otherMouse*`，在回调里跑状态机判断 `.modifierOnly` 类型快捷键的按下/释放 [source: github.com/Beingpax/VoiceInk/blob/main/VoiceInk/Features/Shortcuts/Coordination/ShortcutMonitor.swift#L100-L260]。左右区分**不是**靠 device-level flags bit，而是直接比较 `keyCode`（如 `kVK_RightCommand` 常量，`Shortcut.swift#L72-L75,#L103-L122`）。录制用户配置走自家 `ShortcutRecorder.swift`（未用 KeyboardShortcuts 库，因为它不支持录 modifier-only）。防重复触发：`requiresStandaloneRelease`+`isInterrupted` 状态——若 modifier 按下期间有其它 keyDown/mouseDown，标记 interrupted，释放时不触发；`handleShortcutInterruptions` 把这类"被打断"的 chord 单独上报，双击/误触通过 keyCode 级别的按下记录过滤 [source: 同文件 `#L280-L340`]。

**Handy**（Rust/Tauri）：不用 sindresorhus/KeyboardShortcuts（那是 Swift 库，Handy 是跨平台 Rust）。Handy 自家 `handy-keys` crate（`HotkeyManager`/`KeyboardListener`，`src-tauri/src/shortcut/handy_keys.rs`），在独立 manager 线程里轮询 `try_recv()`拿 `HotkeyState::Pressed/Released` 事件，统一经 `handler.rs::handle_shortcut_event` 分发到 `TranscriptionCoordinator`，由其按配置的 `shortcut_activation`（toggle / push-to-talk / hold-or-toggle）和 `hold_threshold_ms` 判定按住/松开语义 [source: github.com/cjpais/Handy/blob/main/src-tauri/src/shortcut/handler.rs#L1-L50, handy_keys.rs#L1-L140]。`handy-keys` 本身的 HID-tap vs session-tap 细节未在 Handy 仓库内暴露（它是外部 crate，未找到其源码仓库），**未核实**其具体是 CGEventTap 还是其他机制。

## 4. 合成 modifier 事件被"另一个 app 的 CGEventTap"捕获

两处实证：InputSourcePro 把合成的 keyDown/keyUp **post 到 `.cghidEventTap`**（`CGEvent(...).post(tap: .cghidEventTap)`，`InputSourceSwitcher.swift` `triggerShortcut`），这是系统事件管线的最底层入口（硬件事件进入 WindowServer 前的位置），比 `.cgSessionEventTap`（会话级，所有已登录 session 的事件在分发给具体 app 前）更靠上游；**在 HID tap 处注入的事件，下游所有 session-level tap（含目标 app 自己的 tap，以及系统热键处理）都会收到**，这正是让"系统切换输入法快捷键"被系统本身处理、驱动 TIS 真正切换的原理依据（Apple doc: `CGEventTapLocation.cghidEventTap` = "point where HID system events enter the window server", `.cgSessionEventTap` = "point where session events are visible to all applications" [source: developer.apple.com/documentation/coregraphics/cgeventtaplocation]）。InputSourcePro 同时用 `eventSourceUserData` 魔数（`isSyntheticEvent`）+ 进程 PID 比对，在**自家**的 tap 回调里显式放行/忽略这些合成事件，防止自我污染状态机——这证明合成事件默认不会被系统过滤掉，而是要应用自己判断要不要处理它 [source: InputSourceSwitcher.swift#L60-L80, ShortcutTrigger.swift 中 `isSyntheticEvent` 调用点]。

## 该抄的点

1. **CJKV 二段确认 + fallback**：选源后用 timer 回读 `TISCopyCurrentKeyboardInputSource` 校验是否真的生效，不等于直接假设成功——这是修"按一次没反应"的核心。
2. **"抢焦点"而非固定 sleep**：macism/InputSourcePro 都是靠"新窗口拿到键盘焦点"这个事件触发 TIS 真正提交切换，而不是单纯 delay 200ms——纯延时在某些机器/负载下不够。
3. **合成事件要打标记**：用 `eventSourceUserData` 或进程 PID+时间窗，在自己的 tap/monitor 里主动放行合成事件，避免自己截自己的胡（当前 bug 里"切回已经是 WeType 时不触发"很可能是合成 flagsChanged 被自己的逻辑或 WeType 内部状态机吞掉/去重掉）。
4. **suppressSyntheticEvents 时间窗**：围绕整段切换+合成按键流程设一个几百 ms 的"忽略期"，防止中途真实事件和合成事件打架。
5. **modifier-only 一律不走 KeyboardShortcuts 类库**：该库官方确认不支持 Caps Lock/单 modifier 这类场景，必须自建 CGEventTap/NSEvent flagsChanged 状态机（含按下其它键/鼠标/滚轮即判定"打断"的逻辑）。
6. **tap 位置选择要匹配意图**：吞物理按键用 `.cgSessionEventTap`+`headInsert`（能拦截事件，`.defaultTap`非 `.listenOnly`）；而要让 WeType 自己的 push-to-talk 响应，必须把合成事件 post 到 `.cghidEventTap`，这样它才会沿管线往下走、被 WeType 的 tap/系统 TIS 处理到。

## 未核实（not verified）

- `handy-keys` crate 内部是否用 CGEventTap、tap 在 HID 还是 session 级、如何做左右 option 区分——其源码仓库未找到（未在 cjpais 账号下），只读了调用方代码。
- WeType（微信输入法）自身 push-to-talk 监听的是哪一层事件（NSEvent/CGEventTap/HID），属于闭源黑盒，无法读源码验证；本报告的"为何需要 cghidEventTap"推理基于 Apple 官方 tap-location 文档 + InputSourcePro 的工程实践，非对 WeType 源码的直接验证。
- 用户 app 报的"已经是 WeType 时不触发"具体根因未在任何一个参考仓库中找到完全对应的 bug 描述；上面列出的"合成事件打标记/去重"只是同类问题（VoiceInk 的 interrupted chord、InputSourcePro 的 syntheticEventEndTime）的相似修法，不是确诊。
