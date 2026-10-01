# App Intents Prior Art 调研 — "Unable to communicate with Hijack" 诊断

## 1. 开源 macOS App 如何构建 App Intents

- 绝大多数能跑通 App Intents 的开源项目都是 **Xcode 工程**(.xcodeproj/.xcworkspace),让 Xcode 的 build system 自动调用 `appintentsmetadataprocessor`,而不是手动调 swiftc/xcrun。例子:`paulgessinger/swift-paperless`(PR #613)把 `UploadDocumentIntent`/`AppShortcutsProvider` 直接放进主 app target(未新建 target、未改 project.yml),靠 Xcode 工程自带的 metadata 抽取步骤生成 `Metadata.appintents`[source: https://github.com/paulgessinger/swift-paperless/pull/613]。
- `tomada1114/macos-app-template` 是 **XcodeGen + SwiftPM** 的模板(project.yml 生成 .xcodeproj,再 `xcodebuild`),定位就是"不手动开 Xcode 但仍走 xcodebuild 产物"[source: https://github.com/tomada1114/macos-app-template]。
- Scott Willsey 的 "Building and shipping Mac and iOS apps without ever opening Xcode" 整条流水线是 SwiftPM(单测)→ XcodeGen 生成 project.yml→`xcodebuild`(含 `CODE_SIGNING_ALLOWED=NO` 做未签名快速构建,Release 用 Developer ID + `xcrun notarytool`)。**全文完全没有提 App Intents**,说明这类"无 Xcode GUI 但有 xcodebuild"的开源实践里也没人绕开 xcodebuild 这一步去纯用 swiftc[source: https://scottwillsey.com/building-and-shipping-mac-and-ios-apps-without-ever-opening-xcode/]。
- `fsnow/cst` 的 App Intents 规划文档明确把它当作"引入 Xcode/swiftc 这个全新外部工具链"的大改动,并把"非 Xcode .app 里嵌入 Metadata.appintents 能否被系统发现"列为**最大的未知数**,与我们现在卡住的问题几乎一致[source: https://github.com/fsnow/cst/blob/main/docs/features/planned/APP_INTENTS_SUPPORT.md]。
- 未发现任何成功案例是"纯 swiftc + 手动跑 appintentsmetadataprocessor,零 Xcode 工程"跑通线上可执行的 App Intents;找到的全部是 Xcode 工程(即使用 XcodeGen 生成)。

## 2. "Unable to communicate with <app>" 已知成因

- **TeamIdentifier 缺失是目前证据最强的成因**:Siri Shortcuts 相关开发实录明确写到,App Intents 的 action descriptor 需要 `TeamIdentifier`(来自 `codesign -dv` 的 `TeamIdentifier=` 字段);没有它,"Shortcuts daemon cannot route the intent to the correct code-signed extension, so the workflow hangs indefinitely"。加上 TeamIdentifier 后,同一个 intent 从"永不返回"变成约 130ms 返回[source: https://web.navan.dev/posts/2026-04-06-programatically-creating-and-running-siri-shortcuts.html]。
- **ad-hoc/self-signed 直接复现我们的症状**:`vorssaint-utils` 的一个 Issue 实测——用 ad-hoc 或 self-signed 签名时 Shortcuts action 会出现(即"被列出"),但运行约 30 秒后失败,日志是 `LinkDaemon.ProcessRegistry.Errors`,`linkd` 系统日志报告"无法取得 team identifier";换成 Apple Development 证书(有真实 Team ID)后问题解决,官方 Developer ID 签名的正式发布版同理可用[source: https://github.com/vorssaint/vorssaint-utils/issues/2476]。这与 Hijack 的 `TeamIdentifier=not set` 高度吻合。
- **AppShortcutsProvider/AppIntent 必须在主 app target**:放进独立 framework 或 SPM 包会报 "No AutoShortcuts instance registered.";`AppShortcutsProvider` 及其声明的所有 AppIntents 必须和主 target 在一起[source: https://developer.apple.com/forums/thread/759160]。Hijack 是把它们放进 main app binary,这条排除。
- **进程未正常退出导致后续运行失败**:若上一次 intent 执行后 app 进程未退出,后续 Shortcuts 运行会"悄悄失败,没有任何提示",本质是陈旧进程占用导致新连接建立不了[source: https://developer.apple.com/forums/thread/759160 综述段]。Hijack 本身是常驻菜单栏 app(本来就一直在跑),这条風险较低但仍可能叠加。
- 其他已知坑(未直接命中但常伴随此报错):`AppShortcutsProvider`/`AppIntent` 命名冲突导致 metadata processor 报重复标识符(Xcode 16 已知 bug,表现为构建期报错而非运行期)[source: https://marcpalmer.net/changes-in-app-intents-pre-processing-causing-confusing-errors-in-xcode-16/];`perform()` 返回值与声明的 `ProvidesDialog`/`ReturnsValue` 不匹配导致崩溃;XPC 连接失效(`NSCocoaErrorDomain Code=4097`)[source: https://developer.apple.com/forums/thread/694700 关联讨论综述]。

## 3. SwiftPM 能否单独完成 App Intents metadata 抽取

- **不能,目前(2024–2026 多篇 2026 年早期的论坛帖持续确认)**:SwiftPM 默认把包编译为 static library,而 App Intents 的 metadata 抽取步骤只存在于 Xcode **dynamic framework target** 的构建流程里,static library/纯 SwiftPM 可执行目标没有这一步[source: https://developer.apple.com/forums/thread/759160]。
- `AppIntentsPackage` 协议(WWDC24 引入)可以让放在 SPM 包里的 AppIntent 类型被主 app 发现,但**前提仍是包和主 target 都在 Xcode 工程体系里构建**,且 `AppShortcutsProvider` 本身仍必须留在主 app target,不能单独从 SwiftPM 包里产出完整可用的 `Metadata.appintents`[source: https://developer.apple.com/forums/thread/759160]。
- 没有找到任何证据表明一个**完全脱离 xcodebuild/Xcode 工程、只用 `swift build`/裸 `swiftc`** 的可执行 target 能可靠拿到等价于 Xcode 产出的 `Metadata.appintents` 并被系统正确索引+路由执行(我们现在手动跑 `-emit-const-values-path` + `appintentsmetadataprocessor` 正是在复刻 Xcode 内部步骤,"listed 但 execute 失败"恰好符合"extraction 格式对了、但运行期签名/路由信息缺失"的已知失败模式)。

## 最可能的原因(按可能性排序)

1. **TeamIdentifier=not set(自签名证书,无 Apple Team ID)**——系统/linkd/Shortcuts daemon 需要用 Team ID 做 code-signed extension 路由,self-signed 证书下列出但执行即失败/超时,与 vorssaint-utils 和 navan.dev 两条独立证据完全吻合[source: https://github.com/vorssaint/vorssaint-utils/issues/2476][source: https://web.navan.dev/posts/2026-04-06-programatically-creating-and-running-siri-shortcuts.html]。
2. **手动跑 appintentsmetadataprocessor 产出的 Metadata.appintents 与 Xcode 内部实际产出存在字段/格式差异**(例如缺少某些由 Xcode build system 自动注入的签名关联信息),导致"能被发现列出"但运行期握手失败——这是 fsnow/cst 文档标注为"最大未知数"的方向,与我们"自己手动跑工具"的做法直接相关[source: https://github.com/fsnow/cst/blob/main/docs/features/planned/APP_INTENTS_SUPPORT.md]。
3. Hardened Runtime / 缺少必要 entitlements(自签名证书通常也没有正确配置 entitlements,与原因 1 常常同时发生,难以单独验证)。
4. App 启动方式(main.swift 手写 `NSApplication.shared.run()`)导致 XPC/Apple Event 握手路径与标准 `@main App` + Info.plist 自动生成的路径不同——目前没有直接证据,列为低优先级假设。

## 推荐做法

**标准、最少手搓的路径 = Xcode 工程(哪怕由 XcodeGen 生成)+ 真实 Apple Developer Team ID 签名,让 `xcodebuild` 自动跑 `appintentsmetadataprocessor`:**

1. 用 XcodeGen 写一个 `project.yml`,把现有 main.swift/源码原样接进去生成 `.xcodeproj`(不需要手动点 Xcode GUI,仍是 CLI/脚本驱动,符合"不手开 Xcode"的诉求),参考 `tomada1114/macos-app-template` 与 Scott Willsey 的流水线[source: https://github.com/tomada1114/macos-app-template][source: https://scottwillsey.com/building-and-shipping-mac-and-ios-apps-without-ever-opening-xcode/]。
2. 用 `xcodebuild -scheme Hijack build`(或 `archive`)代替手动 `swiftc` + 手动 `appintentsmetadataprocessor` 调用,让 Xcode build system 自己决定何时/如何跑 metadata 抽取,避免第 2 条"手搓格式差异"风险。
3. **申请 Apple Developer Program(US$99/年),拿到真实 Team ID**,用 Developer ID Application 证书签名(配合 `codesign --options runtime` 开 Hardened Runtime,后续分发建议走 notarize)。这一步是**必需项**而非可选项——几乎所有证据都指向 self-signed/无 Team ID 是"listed 但不可执行"的根因。
4. 可选但推荐:构建后用 `codesign -dv --entitlements - Hijack.app` 核对 `TeamIdentifier=` 字段确实非空,再用真机(非模拟)跑一次 Shortcuts action 验证。
5. App Intents Extension(独立 extension target)不是必需——`AppShortcutsProvider` 本来就要求和 intents 放在主 app target,维持现在"塞进主 binary"的结构即可,不必拆 extension[source: https://developer.apple.com/forums/thread/759160]。

## 未核实

- 是否存在"用非 Apple 签发证书但仍让 Team ID 字段非空"从而绕过限制的办法——未找到相关证据,倾向认为不存在。
- 手动 `-Xfrontend -const-gather-protocols-file` + `appintentsmetadataprocessor` 产出的 `Metadata.appintents` 与 Xcode 自动产出之间的**具体字节级/字段级差异**——没有找到逐字段对比的公开资料,只能推断方向。
- macOS 27 / Xcode 27A266a 这个具体版本组合是否引入了新的已知 bug(搜索结果里的案例集中在 Xcode 14–16,未覆盖到 27)。
- LSUIElement + 自定义 `main.swift`(非 `@main struct App`)是否对 App Intents 的 XPC 握手有额外影响——未找到直接证据。
