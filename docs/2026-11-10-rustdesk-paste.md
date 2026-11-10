# RustDesk 中识别正常，但 Windows 没有收到文字

用户已打开 RustDesk 的 Control／Command 置换，按语音热键能录音、能看到识别文字，但没有输入到远端 Windows。Mac 上安装的是 RustDesk 1.5.1，bundle id 为 `com.carriez.rustdesk`。

## 原因与修复

原来的 `Paster.paste` 把文字放进 Mac 剪贴板，立即发送两个 V 事件，只在事件上带 Command 标记。RustDesk 的映射模式转发按键码，V 上的标记不能代替独立的 Command 按下／松开。参考 [RustDesk 的键盘映射](https://github.com/rustdesk/rustdesk/blob/master/src/keyboard.rs)和 [Control／Command 置换](https://github.com/rustdesk/rustdesk/blob/master/src/ui_session_interface.rs)。独立事件之外，还需要下述左侧设备标志。

粘贴从 `Audio.swift` 拆到 `Paster.swift`，生成完整的 Command 按下 → V 按下 → V 松开 → Command 松开事件，使用私有事件源，避免继承用户当前按住的其他修饰键。RustDesk 仍负责把 Command 转成 Windows Control，不发送两套快捷键，避免重复粘贴。

第一版补了独立事件，用户实测仍只输入 `v`，触发 Windows 中文输入法的 V 模式。进一步核对 Flutter 的 [KeyCodeMap_Internal.h](https://github.com/flutter/engine/blob/main/shell/platform/darwin/macos/framework/Source/KeyCodeMap_Internal.h) 和 [FlutterEmbedderKeyResponder](https://github.com/flutter/engine/blob/main/shell/platform/darwin/macos/framework/Source/FlutterEmbedderKeyResponder.mm)：macOS 转换器读取左／右修饰键的设备位，只设通用 `.maskCommand` 不足以表示左 Command 正按着。最终实现给 Command 按下、V 按下和 V 松开全部带 `kModifierFlagMetaLeft`（`0x8`），直到 Command 松开才清掉；只在 Command 事件加设备位、V 不带也会让 Flutter 合成提前释放。

只在准确匹配 RustDesk bundle id 时启用以下等待：先写普通文本剪贴板，等 0.7 秒再发按键；按键后保留文字 2 秒，再按设置恢复原剪贴板。RustDesk 的[剪贴板轮询间隔](https://github.com/rustdesk/rustdesk/blob/master/src/clipboard.rs)是 333ms，0.7 秒覆盖两轮轮询，但不代表已获得远端同步确认。远程文本不加 `TransientType`，使同步程序能按普通复制读取；这也意味着剪贴板管理器可能记录这一条。

连续的远程句子排队，直到前一句消费等待结束才写下一句，避免后一句覆盖还没同步的前一句。等待中切换了应用或剪贴板被改写，不再发送旧的粘贴按键；取消会记日志，文字仍可从识别历史复制。恢复时继续检查剪贴板 changeCount，保留用户后来复制的内容和旧剪贴板的所有格式。本机粘贴仍立即发按键，按原来的 0.8 秒恢复，不加远程等待。

## 验证与限制

`PasterTests.swift` 使用独立命名剪贴板、虚拟时钟和内存按键接收器，不修改系统通用剪贴板，不向当前应用发送按键。覆盖事件的按下／松开、远程等待、本机立即输入、连续两句、切换应用、用户重新复制、关闭恢复、原剪贴板为空和多格式恢复。

```sh
swiftc -swift-version 5 -module-cache-path client-mac/build/mcache client-mac/Sources/Paster.swift client-mac/Sources/Log.swift client-mac/Tests/PasterTests.swift -o client-mac/build/paster-tests
client-mac/build/paster-tests
swiftc -O -swift-version 5 -module-cache-path client-mac/build/mcache -o client-mac/build/NBIME client-mac/Sources/*.swift
```

`RustDeskKeyboardProbe.mm` 直接加载本机 RustDesk 自带的 `FlutterMacOS.framework`，在内存中调用真实 `FlutterEmbedderKeyResponder`，不启动引擎、不向当前应用或远端发送按键。Swift 测试把 `PasteDelivery.shortcut()` 的生产事件转换成 NSEvent 交给它，检查 V 按下时左 Command 确实按着、V 和 Command 最后都松开。第一版在此测试中失败（只得到 V，缺 Command）；补上设备位后再验证三种错误实现均能复现故障：全部缺设备位、只有 V 缺设备位、只发带通用 Command 标记的 V。

```sh
clang++ -std=c++17 -fobjc-arc -fblocks -I "$HOME/flutter/engine/src" -c client-mac/Tests/RustDeskKeyboardProbe.mm -o client-mac/build/rustdesk-keyboard-probe.o
swiftc -swift-version 5 -module-cache-path client-mac/build/mcache client-mac/Sources/Paster.swift client-mac/Sources/Log.swift client-mac/Tests/RustDeskKeyboardTests.swift client-mac/build/rustdesk-keyboard-probe.o -lc++ -o client-mac/build/rustdesk-keyboard-tests
client-mac/build/rustdesk-keyboard-tests
```

测试需要 macOS 剪贴板服务；受限沙箱中服务不可达时，需在允许连接该服务的环境运行。Windows 链路由用户亲自实测，确认已能正常语音输入；仍要求 RustDesk 会话开启剪贴板同步，以及 Control／Command 置换。固定等待不能保证很慢的网络一定同步完成。

第一版 29 项自动检查通过，完整客户端编译通过并已安装，但未覆盖 Flutter 的真实修饰键转换，不能证明远端输入成功；第二版增加上述真实转换器检查。原工作区的改字观察相关改动保持原样，不纳入本次提交。

第二版 30 项粘贴回归和 4 项真实 Flutter 转换检查通过，完整客户端编译通过。已用原构建脚本及固定签名安装，并正常退出旧进程、启动新版。用户于 2026-11-10 确认：Windows 上已经能正常语音输入。

日志另显示 RustDesk 的 `AXGroup` 曾触发粘贴前的 4 秒焦点等待。此项保留原有保护逻辑，不把 RustDesk 所有非文本控件都当作输入框；所以识别后可能先等 4 秒，再进入远程粘贴等待。
