# Windows 粘贴弹出剪贴板历史

当前 RustDesk Windows 会话的 `allow_swap_key = false`，但输入法沿用固定 Command+V，导致远端收到 Win+V，打开剪贴板历史。此前的修复依据当时已开启的 Control／Command 置换，未处理配置变化。

修复后读取 RustDesk 聚焦窗口的会话标识，只匹配对应 peer 配置，并读取平台与置换开关：Windows／Linux 未置换发送 Control+V，已置换发送 Command+V；远程 Mac 反向选择。本机仍用 Command+V。左右修饰键设备位、独立按下松开事件、剪贴板同步等待和恢复机制继续保留。

请求还记录远程会话身份与映射设置，在发送前重新核对；同一 RustDesk 进程中切换到另一台机器也会取消旧请求。读不到或无法明确匹配会话时，保留原有 Command+V 行为；本轮已用相同应用签名验证当前会话准确读出 `Windows / swapped=false / Control+V`。配置只读，不修改用户的 RustDesk 设置。

验证：42 项粘贴检查、5 项 RustDesk 自带 Flutter 转换器检查通过，包含 Windows Control+V 的真实转换、Mac／Windows／Linux 的置换组合和同进程切换远程会话。完整应用编译通过。

追加实测：使用同签名探针调用生产 PasteDelivery，在远端新开的 Windows 记事本里成功自动输入「NBIME 自动粘贴测试 123」，不需要点击剪贴板面板。用户随后反馈「现在好了」，确认实际使用恢复。保留当前安装的按会话选择 Control／Command 修复。

另发现左 Option 单按会传到 Windows 成为 Alt，记事本可进入菜单快捷键状态；此状态下后续粘贴未进入正文。仅在隔离探针中试验了修饰键拦截，用户恢复使用后停止远程测试，试验代码已撤回，未安装。该菜单焦点问题与原先 Win+V 打开剪贴板历史的映射问题分开记录，尚未处理。

```sh
swiftc -swift-version 5 Sources/Paster.swift Sources/RustDeskPaste.swift Sources/Log.swift Tests/PasterTests.swift -o /tmp/nbime-paster-tests
/tmp/nbime-paster-tests
```

真实转换器测试沿用 11-10 记录的构建方法，Swift 编译输入另外加入 `Sources/RustDeskPaste.swift`。只读会话探针为 `Tests/RustDeskTargetProbe.swift`，需使用输入法的固定应用签名，才能验证同一辅助功能授权。

## Option 单按触发 Windows 菜单

后续修复由 `RemoteOption.swift` 在 `Hotkey.process` 的真实事件入口处理：仅在 RustDesk 中、Option 已绑定为录音热键且输入法未暂停时，暂存单独 Option 按下；单独松开时一并吞掉。录音期间普通鼠标移动去掉延期的 Option 标志，避免远端根据标志合成 Alt。

一旦出现其他按键、修饰键、鼠标点击或滚动，先通过当前事件钩子的 proxy 补回 Option 按下，再传递原事件，取消本次录音。后续组合事件和松开正常放行，Option+另一个录音热键也不会被吞掉。先按 Ctrl 或普通键再按 Option 同样保留组合操作。暂停、未绑定 Option、录制快捷键设置和本机其他应用保持原行为。事件钩子恢复时清除已松开的延期事件。

验证：`HotkeyTests.swift` 29 项通过，覆盖左右 Option、两种松键顺序、按键重复、多修饰键、鼠标操作、暂停、改绑定及重同步。关闭远端隔离的反测失败 17 项；保留隔离但漏掉补发修饰键的反测失败 8 项。完整应用编译通过。`RemoteOptionProbe.swift` 提供真实事件钩子的 `--single` 和 `--combo` 集成探针，需要先将 Windows 测试记事本置前；真实 Windows 记事本实测已通过：单按 Option 后自动粘贴测试文字，菜单未被激活；Option+F 正常打开文件菜单，探针记录录音取消及松开。探针不采集音频，测试文字用完即丢弃。

```sh
swiftc -swift-version 5 Sources/Hotkey.swift Sources/RemoteOption.swift Sources/Log.swift Tests/HotkeyTests.swift -o /tmp/nbime-hotkey-tests
/tmp/nbime-hotkey-tests
```

已将通过上述检查的完整应用安装至 `~/Applications/NB 输入法.app` 并重新启动；原应用备份在 `/tmp/nbime-before-option-fix/NB 输入法.app`。
