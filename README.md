# NB 输入法

Newbase Lab 内部孵化的 Mac 语音输入小工具。
按住快捷键说话，松开后文字直接进到当前输入框；说话时屏幕底部的胶囊里实时显示预览文字。识别在局域网里的 ITX 上跑（Qwen3-ASR-1.7B），不走云端。

| 目录 | 内容 |
|---|---|
| `client-mac/` | Mac 菜单栏客户端（Swift / AppKit，`Sources/` 下按功能分文件）。`./build.sh` 编译、装到 `~/Applications/NB 输入法.app` 并启动；`--no-run` 只装不启动，`--icon` 重画图标 |
| `server/` | ITX 上 CapsWriter 服务端的部署说明与自启脚本 |
| `tools/` | 调试工具，比如对比热词提示写法的 `hotword_echo_test.py` |
| `design/` | 交互稿 `mockup.html`；`v0.2/` 是 v0.2 实际界面和交互稿的对照截图 |

客户端的本地数据都在 `~/Library/Application Support/NBIME/`：设置 `config.json`、热词 `hotwords.txt`、历史 `history.json`（最近 200 条）。都能在设置窗口里改，不用手动编辑。日志 `~/Library/Logs/NBIME.log`。v0.1（ITX Voice）的设置、热词和日志里的识别记录，新版第一次启动时会自动搬过来。

调试：
- `NBIME --test-file <音频>`：不用麦克风，按实时节奏走一遍同样的发送路径（含流式预览），打印 `PREVIEW` / `RESULT`。
- `NBIME --demo <界面>`：截图用，`listen` `quiet` `preview` `long` `think` `done` `miss` `offline` `menu` `onboarding` `settings:0`…`settings:5`。
- 这两种模式会借用已经开着的隧道，不动它。
