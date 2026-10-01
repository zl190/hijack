Hijack — 可编辑图标源素材

交付状态
这是可直接导入 Icon Composer 的分层源素材，不是成品效果图。
当前尚不包含已保存、经 Icon Composer 验证的 .icon 原生工程；本机 Icon Composer 首次启动要求接受许可协议，等待用户授权后继续。

文件
layers/01-hat.svg：礼帽独立矢量图层。
layers/02-pointer.svg：指针独立矢量图层。
layers/*.png：同画布、透明背景的栅格导入备选。
Hijack-emblem.svg：包含两个命名分组的可编辑组合源图；在 Composer 中请优先导入两个独立 SVG，便于分别设置材质。
layers.json：图层清单，不是 Icon Composer 的配置格式。
menu/：原有 macOS 菜单栏 Template PNG，保持原样。与 App 图标是两个用途。
source-preview.png：仅用于快速查看源图层，不要把此预览导入 App Icon。

素材约束
所有图层共用 1024×1024 坐标与透明画布，导入时保持画布尺寸、100% 比例、同一原点，不要逐个紧裁再居中。
前景为纯色矢量轮廓，无嵌入位图，无滤镜、阴影、高光、纹理、背景底板或圆角遮罩。
礼帽与指针的外轮廓根据原 Hijack-1024.png 的主体提取并平滑；原效果图内部的凹凸纹理不属于源图层。

Icon Composer 使用
1. 建立 1024×1024、macOS 图标工程。
2. 导入 layers/01-hat.svg 和 layers/02-pointer.svg，保留各自坐标。
3. 用 Composer 设置背景填色；系统负责最终外形遮罩。不要导入旧 PNG 的圆角底板。
4. 在 Default / Dark / Mono 外观中设置颜色和材质；Clear 与 Tinted 使用原生 Mono 相关渲染和系统着色，不应烘焙为四张图片。
5. 建议默认与深色保持原品牌的石墨底＋象牙白前景；按需要在 Default 中调整背景明度。在 Mono 中移除品牌颜色，由系统生成透明与着色外观。
6. 保存 .icon 工程，加入 Xcode target，并将 App Icon 指向工程名。最终需在 Icon Composer 及实际应用中检查各外观。

验证
SVG 可解析；每个独立文件仅含一个纯色 path；两个文件均为 1024×1024；无 image、filter、mask、背景 rect；PNG 导出含真实透明通道。
本包没有声称已经通过 .icon 编译或应用集成验证。

依据
https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer
https://developer.apple.com/icon-composer/

