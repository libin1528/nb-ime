# 本地流式预览与首字延迟

用户希望文字更快跟上说话。本次将 Apple `SpeechTranscriber` 接入实际采样入口，开启 `volatileResults` 和 `fastResults`，以连续音频流驱动识别，而不等待两秒片段收齐。`SpeechAnalyzer.prepareToAnalyze` 在录音前预热，结束后准备下一句。

只使用系统已安装的语言模型，不自动下载。当前这台 Mac 有简繁中文；自动语言模式优先使用普通话模型，指定其它语言时查找对应模型，不可用则使用原有远端预览。模型输出由音频时间范围合并，替换不稳定片段，避免把中间结果重复拼接。现有热词过滤和读音纠正仍应用于预览。

同一批录音采样同时给本地预览和既有识别链路。远端预览作为热备，在本地三秒没有更新或报错时接续显示；最终输入仍来自原有完整识别与润色。停止、取消和新一轮录音均更换会话代次，过期结果不再显示。关闭流式预览时停止本地会话。输入队列有上限，处理落后时回退，避免积压。

## 实测

同一段 8.4 秒中文合成语音，按每 0.1 秒发送音频模拟说话：

- 上一版完整应用远端首段：3.8 秒。
- 新版完整应用本地首字：1.146 秒，说完前 30 次中间文字更新。
- 生产 `LocalPreview` 连续两轮：1.058 秒、1.039 秒；均在说完前持续返回文字。
- 同一轮最终识别正常，松开后含润色 1.070 秒返回完整句子。
- 取消后无旧回调、下一轮预热、不支持语言回退均通过。
- `StreamingTranscriptTests` 的 7 项检查覆盖增量修正、后段追加、跨段改写、空结果撤回和 Unicode。

这些是合成中文的样本数据，不是所有环境下的延迟保证。模型大约每秒处理一轮新音频，再连续输出中间文字；预览可能修正，末尾尚未识别出的字由最终结果补齐。本轮未回放用户真实录音，也未声称英文或中英混说质量已验证。

```sh
cd client-mac
swiftc -swift-version 5 Sources/StreamingTranscript.swift Tests/StreamingTranscriptTests.swift -o /tmp/streaming-transcript-tests
/tmp/streaming-transcript-tests
swiftc -O -swift-version 5 Sources/LocalPreview.swift Sources/StreamingTranscript.swift Tests/LocalPreviewProbe.swift -o /tmp/local-preview-probe
/tmp/local-preview-probe /tmp/nbime-stream-sample.aiff
```

API 依据：[SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)、[预热](https://developer.apple.com/documentation/speech/speechanalyzer/preparetoanalyze(in:))。原有麦克风恢复与界面呈现改动见同日的 microphone-and-preview 记录。
