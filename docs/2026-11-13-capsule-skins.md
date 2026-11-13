# 输入浮窗的三款皮肤

「设置 › 外观」提供 AI 流光、通透玻璃、极简平面，预览复用实际浮窗的 `CapsuleSurface` 和 `CapsuleView`。选择写入 `config.json` 的 `capsuleSkin`；缺失或未知值回退到 AI 流光。录音、实时文字、识别中及结果提示都采用所选皮肤。

- AI 流光保留彩色边缘光效、16 点预览文字与 44 点状态条。
- 通透玻璃采用 15 点文字与 40 点状态条。用户反馈第一版不够透明后，将玻璃材质独立减至 40% 强度，浅色／暗色遮底分别减至 6%／4%；文字单独叠放，保持完整不透明度。
- 极简平面采用 12 点预览文字、28 点状态条和 300 点展开宽度，不使用玻璃、彩光或浮窗阴影。三款均最多显示最后三行文字。

第一版极简模式的内容离开 `NSGlassEffectView` 后仍沿用玻璃容器的布局方式，浮窗展开时内容尺寸停在 230 × 44，造成状态拥挤、预览被裁掉。修复是在移出玻璃容器时恢复 `translatesAutoresizingMaskIntoConstraints`，让内容按父视图伸缩。实际窗口由圆点尺寸展开的回归检查在修复前失败 4 项，修复后通过。

`CapsuleSkinTests.swift` 共 69 项检查通过，包含旧配置回退、切换保留文字、圆点到展开尺寸同步、三行上限、识别中保留尺寸、结果状态和减少透明度的实色底。通透玻璃和极简模式还用原生窗口人工核对：彩色背景及线条可以透出玻璃，极简展开后两行预览和底部状态各自在正确位置。系统开启「减少透明度」时使用实色底。

```sh
cd client-mac
swiftc -module-cache-path /tmp/nbime-skin-module-cache -swift-version 5 $(rg --files Sources -g '*.swift' | rg -v '/main.swift$') Tests/CapsuleSkinTests.swift -o /tmp/nbime-skin-tests
/tmp/nbime-skin-tests
```
