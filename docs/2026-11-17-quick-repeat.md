# 三次短按重贴最近一句

按用户确认的交互，同一输入快捷键从第一次按下到第三次松开不超过 1 秒，且每次都短于当前设置的起录阈值，第三次松开后重贴一次。支持修饰键、普通键和鼠标侧键，包含当前绑定的 Fn 与鼠标侧键 5。每组三次独立计算；一两次短按、自动重复和同时按住两个快捷键不会触发。不同快捷键交替不算同一组。

`Hotkey.process` 保留每次正常按下／松开回调和原有 RustDesk Option 隔离。按住达到起录阈值仍正常录音；组合键、其他键入、鼠标点击／滚动、暂停、绑定或设置变化、录制快捷键和事件钩子重同步清除连击。普通鼠标移动不打断。原有短按的 `.holding` 分支停止录音，不发识别请求；等待上一句焦点的粘贴改到确认按住说话时执行，前两次短按不再提前冲掉等待。

第一次按下先走正常录音准备，再保存最近最终结果，并离开事件钩子回调异步读取完整 AX 上下文；核对已有的首次按下焦点和应用，避免为三连按等待而推迟正常起录。第三次松开后留 0.15 秒给快捷键释放，逐字重贴原结果，不重认、不润色、不追加逗号、不新增历史。没有历史或读不到输入位置时取消。

普通应用须为原生文本角色或支持选区的可编辑元素；RustDesk 须满足菜单重新输入的已确认会话、窗口和画面焦点条件。连击中、入队前、同步后发键前重新核对焦点和最近结果；若另一句最终识别结果已经到达，也取消本次重贴。继续使用原粘贴队列、映射、0.7 秒同步、2 秒恢复和用户新复制保护。显式重贴时移除同句尚在等焦点的旧定时器，避免随后再输入一次。

## 验证

Mac mini：macOS 27.0.1、Swift 6.4、目标 `arm64-apple-macosx26.0`，走现有共享设备锁。

| 最终快照执行项 | 通过 | 失败 |
|---|---:|---:|
| `QuickRepeatTests`：生产 Hotkey → RecentRepeat → PasteDelivery | 84 | 0 |
| `HotkeyTests`：原有 Option、组合键等回归 | 29 | 0 |
| `RetypeTests`：菜单重输与焦点回归 | 65 | 0 |
| `PasterTests`：剪贴板、映射和队列回归 | 42 | 0 |

共 220 项通过，0 失败、0 跳过，完整优化编译通过。测试使用独立剪贴板、虚拟时钟与内存事件，不开麦、不安装全局事件钩子。

```sh
cd client-mac
swiftc -swift-version 5 -target arm64-apple-macosx26.0 \
  $(rg --files Sources -g '*.swift' | rg -v '/main.swift$') \
  Tests/PasteClock.swift Tests/QuickRepeatTests.swift -o /tmp/nbime-quick-repeat-tests
/tmp/nbime-quick-repeat-tests
swiftc -O -swift-version 5 -target arm64-apple-macosx26.0 Sources/*.swift -o /tmp/NBIME
```

独立副本上跑整份 `QuickRepeatTests` 的反测：两次短按就触发失败 33 项；忽略一秒总窗口失败 1 项；把长按也计入失败 3 项；去掉输入上下文复核失败 5 项；忽略最近结果变化失败 2 项；允许迟到的焦点查询遗留快照失败 2 项。

主力机 macOS 26.6.2：沿用本轮用户明确授权的原生焦点验证，运行 `python3 tools/retype_native_test.py --workdir /tmp/nbime-repeat-native`，33 项通过，0 失败、0 跳过。包括原生文本框允许、按钮及普通 AXGroup 拒绝、实际菜单 AX Press、三连按调用生产协调器并经真实 AX 树进入粘贴队列；菜单重输发送回调约 1.25 秒。测试窗使用模拟 RustDesk 会话，三连按按键只送入生产 `Hotkey.process` 内存入口，粘贴事件不发到真实应用或远端。

追加只读现场核对：主力机真实 RustDesk 当前会话可识别，`AXGroup` 归属聚焦窗口、无阻断弹层，生产 `RetypeFocus.capture` 返回可用；不切前台、不读输入正文、不写配置、不发送按键。

未验证：安装后物理快捷键与真实麦克风的完整连击现场；本轮没有再次在 Windows 远端编辑器实发文字。原音频、识别、润色代码和热词表未改。构建号升至 11，包含前一笔构建 10 的 RustDesk 修复。
