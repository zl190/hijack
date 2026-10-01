Hijack — 四种外观素材

Default：浅色底、石墨色礼帽和指针。
Dark：原压缩包的深色图标，保留原设计。
Clear：银色磨砂玻璃外观参考；含 alpha，但主体与底板大部分接近不透明，外围杂点和毛边已通过像素蒙版清理，透明通道已校验。不是已完成的原生动态 Clear 图标。
Tinted：中性灰度着色母版，没有绑定某一种强调色。

四张 PNG 均为 1024×1024。Default 外围为烘焙黑色背景，其余含 alpha。这套是视觉素材交付，不是可直接编译的 .icon 工程。若要正式上线，Default 需处理外围背景，Clear 需拆为前景与背景图层，然后在 Icon Composer 中设置材质与外观；系统最终的 Clear 和 Tinted 效果由系统生成。

原菜单栏模板保存在 menu/，未修改。
preview.html 为四种外观对照。

依据：
https://developer.apple.com/design/human-interface-guidelines/app-icons/
https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer

生成方式：built-in image_gen。提示词见 generation-prompts.txt。


Clear 清理：经用户授权使用 ImageMagick 像素蒙版。以干净预览的外轮廓生成蒙版，轻微内缩和抗锯齿处理后与原 alpha 相乘；保留可见区域的原图 RGB 像素；透明度为零的区域同步清空隐藏颜色，避免部分预览器显示残留。已检查浅色、深色、蓝色背景。
