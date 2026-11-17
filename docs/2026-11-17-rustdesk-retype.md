# RustDesk 菜单重新输入等待四秒

历史日志里找到 18 次菜单重新输入后将 RustDesk 的 `AXGroup` 判为非输入框、等待四秒的记录。重新输入没有录音开始时的焦点，调用 `strayFocus(from: nil)`，因此远程画面也被当成了新出现的非输入区域。

菜单打开时记录原应用中已确认的 RustDesk 会话、窗口和画面焦点。菜单关闭后，只在应用、会话、映射、窗口、AX 元素均未变化，且没有弹层时，直接进入原粘贴队列。普通应用、RustDesk 启动页、按钮、输入框及无法确认的会话继续使用原焦点判断，`EditWatcher.strayFocus` 未修改。

捕获阶段读取原应用的 `AXFocusedUIElement`，因为状态菜单跟踪时系统全局焦点可能暂时为空；关闭菜单后重新读取系统焦点。准备写剪贴板、同步等待结束发送按键时继续复核。目标变化则取消，不回退粘到新应用。保留 0.15 秒菜单关闭等待、0.7 秒远程同步、2 秒保留剪贴板、串行队列、Control／Command 映射和用户新复制内容的保护。

菜单数据仍在 `menuNeedsUpdate` 中重建，跟踪期间不覆盖首次焦点快照。Apple 的 [menuNeedsUpdate 文档](https://developer.apple.com/documentation/appkit/nsmenudelegate/menuneedsupdate(_:))说明它在菜单跟踪开始时更新菜单；[menuWillOpen 文档](https://developer.apple.com/documentation/appkit/nsmenudelegate/menuwillopen(_:))要求该回调中避免修改菜单结构。

## 验证

Mac mini：macOS 27.0.1、Swift 6.4，编译目标 `arm64-apple-macosx26.0`，使用现有共享设备锁。

| 执行内容 | 通过 | 失败 |
|---|---:|---:|
| `RetypeTests`：生产菜单项、重新输入协调器和粘贴队列 | 65 | 0 |
| `PasterTests`：剪贴板、队列、会话与按键映射 | 42 | 0 |
| `HotkeyTests`：Option 单按隔离与组合键放行 | 29 | 0 |
| `EditFieldTests` | 33 | 0 |
| `TranscriptTests` | 204 | 0 |
| `PreviewTests` | 29 | 0 |
| RustDesk 1.5.1 自带 Flutter 转换器 | 5 | 0 |
| RustDesk 1.5.3 自带 Flutter 转换器 | 5 | 0 |

共 412 项通过，0 失败、0 跳过，完整应用优化编译通过。转换器版本分别来自主力机 1.5.1 和测试机 1.5.3，未发送真实远程按键。编译命令：

```sh
cd client-mac
swiftc -swift-version 5 -target arm64-apple-macosx26.0 \
  $(rg --files Sources -g '*.swift' | rg -v '/main.swift$') \
  Tests/PasteClock.swift Tests/RetypeTests.swift -o /tmp/nbime-retype-tests
/tmp/nbime-retype-tests
swiftc -O -swift-version 5 -target arm64-apple-macosx26.0 Sources/*.swift -o /tmp/NBIME
```

在最终产品源码的独立副本上运行整份 `RetypeTests` 反测：移除菜单快照失败 3 项；把其他应用和未知会话的 `AXGroup` 一并放行失败 4 项；去掉粘贴队列的焦点复核失败 2 项；菜单刷新覆盖原快照失败 2 项。

Mac mini 停在锁定的登录桌面，原生桌面验证无法执行。用户随后明确授权在主力机测试；主力机 macOS 26.6.2 执行：

```sh
python3 tools/retype_native_test.py --workdir /tmp/nbime-retype-native
```

24 项通过，0 失败、0 跳过。隔离 AppKit 宿主提供真实 AXGroup、输入框、按钮、弹层、启动页、窗口和会话切换；生产菜单经原生 AX Press 选中重新输入，发送回调延迟约 1.24 秒，保留同步等待并恢复独立剪贴板。模拟会话只读测试目录里的平台／置换文件，不读取真实 peer 凭据；粘贴事件只在内存里记录。

边界：以上原生宿主并非 RustDesk 的真实远程画面，未再次在 Windows 远端编辑器实发文字。历史日志只用于定位此前的等待原因，没有足够的窗口身份信息可重放当时完整焦点。历史正文、录音、凭据与应用二进制均不入库。热词和识别／润色规则未改。构建号升至 10。
