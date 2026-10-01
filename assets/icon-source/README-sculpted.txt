Hijack — sculpted native app icon

主交付：Hijack.icon
这是原生 Icon Composer 工程，已通过 Apple ictool 六种外观渲染和 Xcode actool 编译。
默认外观为象牙白底＋石墨色前景；深色为石墨底＋象牙白前景。Clear 和 Tinted 使用 Mono 外观配置，由系统生成浅色／深色变体。

保留的造型
礼帽的帽冠凹面、圆润转折、帽檐厚度，以及指针的体积明暗，都保留在独立透明前景 PNG 中。
这不是把完整效果图塞进图标：前景图片没有圆角底板、完整画布背景或投到背景上的阴影；背景、外形遮罩和接触投影由原生渲染器控制。
内部塑形明暗属于有意保留的栅格绘制内容，不是可旋转的三维几何模型。各前景层可在 Icon Composer 中替换、变换、调节效果；若要逐像素改内部造型，编辑 Assets 中相应 PNG。

文件结构
Hijack.icon/icon.json：原生工程定义；一个前景组、六个源图层（Default / Dark / Mono 各有礼帽和指针）。外观对应图层通过 opacity-specializations 切换。
Hijack.icon/Assets/：六张 1024×1024 透明前景 PNG，保留完整图层画布坐标。
source-masks/：前景外轮廓 SVG，仅用于蒙版修改，不是替代立体前景的主图层。
previews/：六张 Apple ictool 直接渲染的 1024×1024 检查图，不是主交付素材。
appearance-preview.png：六种外观的对照图，着色仅用青色演示，实际由系统和用户选择颜色。
compiled/：本次 Xcode 验证得到的 Assets.car、Hijack.icns 与 icon-info.plist。
menu/：原有菜单栏 Template PNG，保持原样。

使用
1. 双击 Hijack.icon，用 Icon Composer 打开和调整。
2. 将整个 Hijack.icon 加到 Xcode 工程并加入 App target；把 App Icon 名称设置为 Hijack。此文件应作为原生工程加入，不要用 previews 中的整张 PNG 代替。
3. 由 Xcode 编译图标资源。compiled/ 是独立验证产物；真实项目应合并编译资源，不能直接覆盖项目已有的 Assets.car。
4. 单独使用 Hijack.icns 只提供静态兼容图标；动态外观需要原生图标资源。
5. App 实际安装后的 Dock／Finder 集成尚未执行；这次修改和验证限定在交付目录，没有修改现有 Hijack App 或仓库。

验证环境与结果
macOS 27.0；本机 Xcode actool 27.0。
ictool：Default / Dark / ClearLight / ClearDark / TintedLight / TintedDark 全部导出成功。
actool：平台 macosx，minimum deployment target 26.0，app icon Hijack，编译成功，无错误或警告。
默认、深色、透明与着色预览中均检查了帽冠凹面、帽檐和指针的体积明暗。
前景画布1024×1024，四角透明，PNG 不包含完整圆角背景。

来源与处理
以前生成的 Hijack-Default-1024.png 和原 Hijack-1024.png 为视觉源；本轮使用已有轮廓蒙版与 ImageMagick 提取透明前景，保留内部形体。未重新生成设计。
原生效果约束参考：https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer
Apple 允许在有意设计并经过测试的图层中保留自定义视觉效果：https://developer.apple.com/design/human-interface-guidelines/app-icons/
