# 语音输入法

按住快捷键说话，松开后文字直接进到当前输入框。识别在局域网里的 ITX 上跑（Qwen3-ASR-1.7B），不走云端。

| 目录 | 内容 |
|---|---|
| `client-mac/` | Mac 菜单栏客户端（Swift，单文件）。`./build.sh` 编译并装到 `~/Applications/ITX Voice.app` |
| `server/` | ITX 上 CapsWriter 服务端的部署说明与自启脚本 |
| `tools/` | 调试工具，比如对比热词提示写法的 `hotword_echo_test.py` |
| `design/` | 交互稿 |

客户端的本地数据：设置 `~/Library/Application Support/ITXVoice/config.json`，热词 `hotwords.txt`，日志 `~/Library/Logs/ITXVoice.log`。
