# 指示词结巴保留量词

## 修复

「这这个种植园」先在本机收成「这个种植园」，再交给模型。只删除「个」前紧挨着重复的「这／那」，不跨标点、不删除「个」或后面的正文；去口误关闭时不处理。

热词、引述、代码和路径、讨论原文或替换的内容保留。「这个个人项目」「每个个体」「那那不能」等不同结构不套用规则。实现见 `DeterminerRestart.swift`，实际入口是 `Polish.prepare`。

收好的「这个／那个」进入输出保护。检查出现次数，不能因为另一处还有同词就放过这一处误删；模型检查失败、出错或超时时退回本机处理结果。未修改提示词、热词或用户档位。

## 测试机验证

设备：Mac mini，macOS 27.0.1（26A434），Apple Swift 6.4；编译目标 `arm64-apple-macosx26.0`。使用现有 `~/.cache/winrig/macmini.lock` 和排队标记，同一时间只执行一项；未抢占其他项目，也未在主力 Mac 跑回归。

实际入口：`python3 -u /tmp/nbime-determiner-20261117/with-mini-lock.py`。它把最小源码和本机历史样本送到隔离目录，执行以下命令后拷回产物。历史正文在完成后从测试机删除，不加入仓库。

```sh
# 在测试机隔离目录内、持有共享锁时执行
xcrun swiftc -swift-version 5 -target arm64-apple-macosx26.0 -module-cache-path module-cache $(rg --files client-mac/Sources -g '*.swift' | rg -v '/main.swift$') client-mac/Tests/TranscriptTests.swift -o transcript-tests
./transcript-tests history.json
xcrun swiftc -swift-version 5 -target arm64-apple-macosx26.0 -module-cache-path module-cache client-mac/Sources/LivePreview.swift client-mac/Sources/HotwordEcho.swift client-mac/Sources/PreviewFilter.swift client-mac/Tests/PreviewTests.swift -o preview-tests
./preview-tests
xcrun swiftc -swift-version 5 -target arm64-apple-macosx26.0 -O client-mac/Sources/*.swift -o NBIME
```

- `TranscriptTests`：109 项逻辑检查及 41,371 条历史验证条目通过，0 失败、0 跳过。
- `PreviewTests`：29 项通过，0 失败、0 跳过。完整应用编译通过。
- 10,576 条历史文本的新规则检查和完整预处理对照，只改变已确认的那一条，其余 10,575 条保持原有结果。
- 5,754 组历史识别与润色／实际输入输出对照，只新增拦截两次此前实测中吞掉量词的输出。另回放上一轮 14,465 条样本，热词与释字行为保持通过。
- 拿掉生产入口修复：整份测试文件失败 18 项。最像的错实现（只查 contains、不查次数）：失败 1 项。反测使用仓库外副本，没有改写工作区产品文件。

真实润色对照也在同一 Mac mini 共享锁内执行，入口为 `python3 -u /tmp/nbime-determiner-20261117/live-lock.py`。探针直接编译产品 `Polish.run`，仅用测试连接参数代替设置读取，经临时回环 SSH 转发调用原有私有润色服务，不修改用户配置。

13 句 × 去口误中／强两档，整理格式固定中：旧、新各调用 26 次。10 次目标场景均保留完整「这个／那个」，16 条正常对照与旧版输出一致，0 失败、0 跳过。探针没有验证设置读写、GUI 或语音识别。

上述历史条目包括重复文本和调试重放，不等于独立语音输入次数；没有重新识别全部历史录音。macOS 26 的自动化回归未执行，部署目标版本不冒充实际测试机版本。

## 安装现场核对

主力 Mac 为 macOS 26.6.2。仅做编辑、`git diff --check`、`plutil -lint` 和安装现场核对：沿用原证书签名测试机产物，安装构建 8，签名验证通过，单个进程运行，辅助功能权限有效。旧版应用保留在本机临时目录。主力机未编译或执行自动化回归。
