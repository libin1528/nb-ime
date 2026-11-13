# 切麦克风后零采样、预览热词回声与文字呈现

2026-11-13。用户反馈切换麦克风或睡眠唤醒后必须重启输入法，预览偶尔突然显示大量热词，希望说话时的文字预览更接近 Siri 的连贯感。

## 断流恢复

当晚切到内置麦克风后，按住两三秒，日志里的音频长度却是 0.0 秒。系统能枚举内置麦克风，但该进程的 CoreAudio 日志显示输入流被禁用。

- 系统默认设备由 AVAudioEngine 建立输入输出组合，不再把共享 IO 单元强制改绑到仅输入的设备；选择非默认设备时仍显式指定，失败则报错。
- `Recorder` 监听设备变化和唤醒通知，空闲时只准备引擎，正在按住时恢复当前录音。格式没变但引擎已被系统停掉也会恢复。
- 每 0.25 秒检测状态；连续 1 秒没有转换后的采样，停止旧引擎并重建。全零采样属于静音，不会触发重建。每次按住最多恢复两次，持续失败会结束录音并提示，下次按键仍可重试。
- 每次启动和重建带有独立代次，旧回调不能串进新录音。松开后保留原有尾音收集，但不再允许后台重开麦克风。
- 停 IO 后拆 tap，旧引擎延迟释放；这与 [Apple 对配置变化通知的说明](https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchangenotification) 一致。

## 热词回声

日志中有「正常句子ClawChat，ClawNest，…」：第一个热词贴在汉字后面，旧逻辑按标点切词时把正常句子和第一个热词当成一个词，整串回声因此漏过。

`PreviewFilter` 在原文中定位热词范围，保留英文单词边界，识别原顺序四词长串、任意顺序五词长串、含重复的三词串，以及整段两个以上热词的情况。每次完整预览都重新过滤，后续累积更新不会把那串词带回来。正常句子里的项目名及短枚举保留。

这是预览显示过滤，不改变完整识别的复核路径。真的连续念多个热词，也可能暂时被预览隐藏，最终输入仍由完整识别处理。

## 文字呈现

- 已经稳定的文字不再淡入；新字和被修正的字按字形渐进出现，未改动的后缀也保留原来的显示状态。
- 同批文字的出现时间最多错开 0.28 秒，再用 0.18 秒淡入，不为长段落增加持续的动画排队。
- 完整返回文本始终参加排版，透明的新字不挤动旧字；超过三行时平滑向上滚动。松开后立即完整显示预览，识别期间保留文字对比度。
- 文字改为 16 点中等字重、25 点行高，光效只沿玻璃边缘流动。系统开启「减少动态效果」时，文字直接显示，光效停止流动。
- 预览识别仍是两秒分段。本轮用 8.4 秒合成语音比较 1.2 秒与 2 秒分段，短分段产生更多半词，首字等待受冷启动和服务端负载影响，未证明稳定改善，因此没有修改识别分段。

## 验证入口

```sh
cd client-mac
swiftc -swift-version 5 Sources/Audio.swift Sources/RecordingEngine.swift Tests/RecorderTests.swift -o /tmp/nbime-recorder-tests
/tmp/nbime-recorder-tests
swiftc -swift-version 5 Sources/LivePreview.swift Sources/PreviewFilter.swift Tests/PreviewTests.swift -o /tmp/nbime-preview-tests
/tmp/nbime-preview-tests
"$HOME/Applications/NB 输入法.app/Contents/MacOS/NBIME" --mic-test
```

`--mic-test` 不保存音频、不发送识别、不粘贴；它模拟本进程收到唤醒和设备变化通知，并未测试整台电脑真的睡眠或物理插拔。长文本浮层已通过原生窗口检查；逐段更新可用 `--demo stream` 查看。
