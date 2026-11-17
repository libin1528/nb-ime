# 跨句重复词保留与 Claude 热词试验

## 已交付的修复

完整句边界两侧重复的汉字短语，可能分别承担上一句的宾语和下一句的主语，不能当作半句重启删除。

`Polish.dropRestarts` 不再跨句号、问号、感叹号、分号或换行（含 CRLF）删重说。逗号、普通空格内的半句重启仍允许，例如「发到测试，发到测试服务器」。`SentenceRestart` 提取句尾／句首重复短语，在模型输出端按出现次数保护；去口误关闭、仅整理格式时也保护。模型误删时退回本机处理后的完整文字。

另按英文整词和出现次数保护正常 `Claw`／`Cloud`，避免长句允许补字的余量被用于改成 `Claude`。没有新增 Claw／Cloud 强制替换，没有修改模型提示词或用户档位。

## 测试设备与结果

Mac mini：macOS 27.0.1（26A434）、Apple Swift 6.4；编译目标 `arm64-apple-macosx26.0`。所有自动化回归、语音重放、真实润色对照和编译都在测试机，沿用 `~/.cache/winrig/macmini.lock` 和排队标记，不抢占其他任务。

入口：`python3 -u /tmp/nbime-sentence-20261117/final-lock.py`，在共享锁内同步最终源码并执行：

```sh
# 测试机隔离目录，持有共享锁
xcrun swiftc -swift-version 5 -target arm64-apple-macosx26.0 -module-cache-path module-cache $(rg --files client-mac/Sources -g '*.swift' | rg -v '/main.swift$') client-mac/Tests/TranscriptTests.swift -o transcript-tests
./transcript-tests history.json
xcrun swiftc -swift-version 5 -target arm64-apple-macosx26.0 -module-cache-path module-cache client-mac/Sources/LivePreview.swift client-mac/Sources/HotwordEcho.swift client-mac/Sources/PreviewFilter.swift client-mac/Tests/PreviewTests.swift -o preview-tests
./preview-tests
xcrun swiftc -swift-version 5 -target arm64-apple-macosx26.0 -O client-mac/Sources/*.swift -o NBIME
```

- 204 项逻辑检查及 16,373 条历史验证条目通过，0 失败、0 跳过；29 项预览检查通过，0 失败、0 跳过。
- 10,611 条历史文本中，预处理有 10 条变化，对应 7 种不同文本，均恢复跨句重复及句子边界。包括「追问卡片」「链接管理」「每日任务」，其余预处理结果保持一致。
- 5,762 组历史识别与输出对照中，7 条此前放行的跨句删减改为拦截（含重复记录）；1 条完整原文由误拒改为通过。18 条差分均逐条检查后登记期望，并未直接把新实现输出整体当作期望。
- 去掉修复：44 项失败；只阻止本机跨句删除却不保护模型输出：14 项失败；去掉英文整词保护：2 项失败。反测使用仓库外副本，跑整份逻辑测试文件。
- 实际产品 `Polish.run` 经私有润色服务做旧新对照：去口误关／中／强、格式固定中，旧新各 36 次。15 次跨句场景保留完整重复短语，21 条正常／合法重说对照输出一致，0 失败、0 跳过。无界面探针只用测试连接参数代替设置读取，不验证 GUI、设置持久化或快捷键。

上述历史条目含重复文本与调试重放，不等于独立语音输入次数。两段跨句问题的原录音已不在保留目录，因此这部分使用历史原始识别文本和模型重放，没有冒充原录音重放。macOS 26 的自动化回归未执行。

## Claude 热词：试验完成，保持词表不变

三段用户手改过的原录音仍在；每段、每个词表各重放三次，调用真实 ASR 后再经过产品替换、读音纠正与润色函数。另用测试机已有系统声音生成 10 条正常 Claw／Cloud 对照，每条每个词表重放三次；这些是合成对照，不是用户原录音。

| 候选词表 | 原录音正确次数：旧 → 新 | 正常对照正确次数：旧 → 新 |
|---|---|---|
| 末尾追加 Claude | 0/9 → 2/9 | 26/30 → 29/30 |
| 首位追加 Claude | 1/9 → 3/9 | 24/30 → 30/30 |

首位候选只修好了“账号”那段，另外两段仍不稳定。正常对照未出现 Claw／Cloud 被改成 Claude，但末尾候选仍有一次回声复核后被认成 Clo。识别有随机性，这些小样本数字不代表普遍成功率。

入口为同目录的 `replay-lock.py`／`first-lock.py`；Swift 探针用客户端相同的 16kHz float32 协议及去重后的实际词表，经临时回环 SSH 转发访问现有私有 ASR／润色服务。第一轮未去重探针的结果已作废，不计入上表。测试后关闭转发、清理测试机上的音频与历史正文，材料不加入仓库。

用户看过结果后选择「保持词表不变，先交付第1项」。没有部署任何 Claude 词表候选，不以强制替换补齐未解决的识别问题。

## 安装核对

测试机产物沿用原证书签名，安装构建 9。主力 macOS 26.6.2 只做编辑、轻量静态检查、签名安装及启动权限核对，不编译、不跑自动化回归。旧版应用保留在本机临时目录。
