# 给 AI 编程助手：帮你的用户搭一个能用的语音输入法

这份文件是写给 agent（Claude Code、Codex、Cursor……）看的。你的用户把这个仓库交给你，想要一个自己的「按住说话、松开输入」的 Mac 语音输入法。照下面的顺序做，每一步都有「怎么确认做好了」。

先记住三件事：

- **这是别人只为自己写的输入法。** 代码里的默认值是照原作者的机器写的（ssh 主机 `winrig`、服务器 `itx-1.local`、一台 Windows 显卡机），你的用户几乎肯定没有这些，第三步会把它们换掉。别在用户的机器上照搬原作者的名字。
- **能自己确认的就自己确认，只有人能做的才交给用户。** 编译、起服务、用音频文件测识别、测润色，你都能自己跑；授权麦克风和辅助功能、亲手按快捷键，只能用户来（系统会丢掉程序模拟的按键）。
- **用用户的语言跟用户说话。** 仓库里的文档、提交记录、界面文字都是中文。界面要不要翻译，问用户。

建议先读：根目录 `README.md` 的「我的环境」「实测过的结论，踩过的坑」两节，再读这份。`server/README.md` 和 `docs/` 里的记录用到时再查。

## 第零步：一次问清楚

一次问完，别一条一条问：

1. Mac 是什么芯片、什么系统？你自己也能查：`sw_vers -productVersion`、`uname -m`。
2. 有没有一台能常开的、带显卡的机器（Windows 或 Linux），和这台 Mac 在同一个局域网里？显存多少？
3. 主要说什么语言？常提到哪些专有名词（人名、项目名、产品名）？
4. 要不要「润色」：松开后让小模型删口误、补标点。要的话 Mac 内存多大？
5. 有没有 Apple 开发者证书？没有也行，只是每次重新编译都要重新打开一次「辅助功能」授权。

## 选一条路

| | A. 只用这台 Mac（推荐先走这条） | B. Mac 本机跑一个识别服务 | C. 局域网里的显卡机（原作者的做法） |
|---|---|---|---|
| 要什么 | macOS 26，别的都不要 | macOS 26，Python 或别的运行时、一个能在 Mac 上跑的识别模型 | 一台常开的 Windows 显卡机，能从 Mac 免密 ssh 过去 |
| 识别 | 系统自带的 `SpeechTranscriber`（离线；普通话、粤语、英语、日语、韩语和法德西意葡，共 30 个地区变体） | 你选的模型（Whisper、SenseVoice、Qwen3-ASR……），包一层和 CapsWriter 一样的 WebSocket 协议 | [CapsWriter-Offline](https://github.com/HaujetZhao/CapsWriter-Offline) + Qwen3-ASR-1.7B |
| 要改代码吗 | 要：在客户端加一个本地识别引擎（下面写了接在哪） | 客户端不改，要写一个小服务 | 不改 |
| 实测 | 原作者的 M5 / macOS 26.6 上：合成的一句中文 0.38 秒出结果，错了一个词 | 没实测，看你选的模型 | 原作者每天在用：松开后约 0.8 秒 |

怎么选：

- 没有显卡机就走 A，几乎不用装任何东西。识别不够准、或者热词不够用，再考虑 B。
- 有一台 Windows 显卡机、愿意折腾部署，走 C。
- CapsWriter-Offline 的服务端官方只保证 Windows 10/11，不支持 macOS，所以别想着把 C 的服务端直接搬到 Mac 上。
- 系统是 macOS 25 或更老：先看第一步最后一条，A 也用不了（`SpeechTranscriber` 是 macOS 26 才有的），只能走 B 或 C。

## 第一步：编译客户端（三条路都要）

1. 确认工具：`xcode-select -p` 有输出，`swiftc --version` 能跑。没有就请用户装 Xcode 命令行工具：`xcode-select --install`，会弹系统窗口，要用户点。
2. 编译并安装：`cd client-mac && ./build.sh --no-run`。
   - 看到「装好了：~/Applications/NB 输入法.app」就是好了。
   - `--no-run` 只装不启动。第三步配好以后再启动，免得它先拿默认配置去 ssh 原作者的机器。
3. 有开发者证书的话，在 `client-mac/sign-identity.local` 里写一行证书名字（`security find-identity -v -p codesigning` 能看到），重编以后辅助功能授权就不会掉。
4. 系统低于 macOS 26 时编译会失败，因为录音胶囊用了 `NSGlassEffectView`。要在 `Capsule.swift` 里把它换成 `NSVisualEffectView`，再把 `Info.plist` 的 `LSMinimumSystemVersion` 改低。这条路没人试过。

## 第二步：识别

### A. 系统自带识别（只用这台 Mac）

要在客户端里加一个本地识别引擎，代替 WebSocket 那条路。

- **接在哪**：`AppController.swift` 里有两个 `ASRClient`（`Network.swift`）。`client` 管完整识别，`preview` 管说话时每 2 秒一次的预览。主控只用到它们的几样东西：`connected`、`onState`（连上 / 断开）、`ping`（设置里测延迟）、`send(_:)`（发一条 JSON：`task_id`、base64 编码的 16kHz 单声道 float32 音频 `data`、`is_final`、热词 `context`）和 `onResult(id, final, text)`。最省事的做法是写一个接口一样的 `LocalASR`，`send` 里把音频攒起来，`is_final` 时交给系统识别、回调 `onResult`。按 `Settings.current` 里的一个新开关选用哪一个，不要删掉 WebSocket 那条路。
- **系统 API**（macOS 26，`import Speech`）：
  - `SpeechTranscriber(locale:preset:)`、`SpeechAnalyzer(modules:)`，喂音频用 `analyzeSequence`（文件）或 `AsyncStream<AnalyzerInput>`（实时），结果从 `transcriber.results` 读。
  - 语言模型没装的话，用 `AssetInventory` 先下载（`SpeechTranscriber.installedLocales` 能看装了哪些）。
  - 热词可以试 `AnalysisContext` 的 contextual strings。具体名字以 SDK 为准，这里没实测。
  - 预览可以直接用 volatile 结果，不必照原作者那样切 2 秒的片段。
  - 第一次用要语音识别权限，`Info.plist` 里加 `NSSpeechRecognitionUsageDescription`。
- **原作者实测过的样例**：上面的 API 写一个 20 行的小程序，转写 `say -v Tingting -o t.aiff "下周一把灯塔计划新的设计稿发给产品经理，顺便看一下登录页的接口为什么返回五百"`，0.38 秒得到「下周一把灯塔计划新的设计稿发给产品经理 ，顺便看一下登陆业的接口为什么返回 500。」。
- **配置**：`tunnelHost` 设成空，不让它去起 ssh 隧道，见第三步。
- **怎么确认**：用 `say` 生成一段语音，跑 `"$HOME/Applications/NB 输入法.app/Contents/MacOS/NBIME" --test-file t.aiff`，会按实时节奏走一遍同样的路径，打印 `PREVIEW` / `RESULT`。`RESULT` 里是那句话就通了。

### B. Mac 本机跑一个识别服务

客户端不改，写一个说 CapsWriter 协议的 WebSocket 服务，监听 `127.0.0.1:6016`。

- **协议**：见 `server/README.md` 最后一节，CapsWriter 源码里是 `core/protocol.py`。客户端怎么发，看 `AppController.swift` 的 `message(...)` 和 `handlePreview`。
- **必须做对的**：
  - 预览和完整识别是**两条连接**，音频缓存要按连接分，不能按任务分（原作者踩过：挤在一起，完整结果会变成空的）。
  - 最后一帧 `data` 为空、`is_final: true`，收到后回 `{"task_id": ..., "is_final": true, "text": ...}`。
  - `context` 是逗号连起来的热词，能用就交给模型。
- **模型**：随你的用户。能在 Apple 芯片上跑的有 whisper.cpp、mlx 系列，有 macOS 版本的 sherpa-onnx（带 SenseVoice）。这里都没实测，先用一段 `say` 生成的语音比一比准确度和速度再定。
- **配置**：`tunnelHost` 设成空，`serverHost` 设成 `127.0.0.1`，`serverPort` 设成 `6016`。
- **怎么确认**：先 `nc -z 127.0.0.1 6016`，再按 A 的办法跑 `--test-file`。

### C. 局域网里的显卡机

照 `server/README.md` 的「从零部署」做，把里面原作者的机器名（`itx-1.local`、`winrig`）换成你用户的。那份文档没写、但你要先弄好的：

- Windows 上开 OpenSSH 服务端，配好 Mac 的公钥，在 Mac 的 `~/.ssh/config` 里给它起个名字（`Host 名字` / `HostName 地址` / `User 用户名`）。`ssh 名字 echo ok` 不用输密码就能回 `ok`，才算好了。
- 服务端只听 `127.0.0.1:6016`，客户端经 ssh 隧道把本机 16016 转过去，所以不用开防火墙端口。
- 没有独立显卡也能跑，CapsWriter 自己的说明里 CPU 识别 20 秒的音频约 4 秒，慢一些。
- 怎么确认：`ssh 名字` 上去看 `logs\server_latest.log` 里有没有收到请求；在 Mac 上按 A 的办法跑 `--test-file`。

## 第三步：配置客户端

配置在 `~/Library/Application Support/NBIME/config.json`。**在 app 没开的时候改**，开着改会被它存设置时覆盖。第一次启动前这个文件还不存在，你可以直接写一份，没写的项用默认值：

```jsonc
// A、B：只用本机，不起 ssh 隧道
{ "tunnelHost": "", "serverHost": "127.0.0.1", "serverPort": 6016, "polishPort": 6017 }

// C：经 ssh 隧道连局域网里的机器
{ "tunnelHost": "你在 ~/.ssh/config 里起的名字", "serverPort": 6016, "localPort": 16016, "polishPort": 6017, "polishLocalPort": 16017 }
```

- **润色**：先不跑润色的话加上 `"polishClean": "off", "polishFormat": "off"`。
- **快捷键**：默认是按住右 Option（`hotkeyCode` 61），用户可以在设置里改，也能设第二个、用鼠标侧键。
- **语言**：`"language"` 默认 `"auto"`，就是中英混说。
- **热词**：写进同一个文件夹的 `hotwords.txt`，一行一个。写 `错的=对的` 是一定替换，比如 `潮汐池、Tide Pool=Tidepool`。

这些也都能在 app 的「设置 › 识别服务 / 润色 / 热词」里改，告诉用户在哪就行。

## 第四步：润色（可选）

润色要一个 OpenAI 兼容的 `/v1/chat/completions` 接口，加一个 `/health`，原作者用的是 llama.cpp 的 `llama-server`。

- **Mac 本机**（A、B）：
  - `brew install llama.cpp`，然后 `llama-server -hf unsloth/Qwen3.5-4B-GGUF:Q8_0 --host 127.0.0.1 --port 6017`。走 Metal，要约 5GB 内存，16GB 的 Mac 够用。这条命令在这台机器上没实测，参数以 `llama-server --help` 为准。
  - 要它开机自己起来，写一个 launchd 的 plist 放进 `~/Library/LaunchAgents/`。
- **显卡机**（C）：照 `server/README.md` 的「润色用的小模型」。
- **Apple 芯片、开了 Apple Intelligence 的 Mac**：还可以试系统的 `FoundationModels`，完全不用装。原作者的 M5 上返回 `deviceNotEligible`，没试出效果。真要用得改 `Polish.swift`。
- **怎么确认**：
  - `curl -s 127.0.0.1:6017/health` 回 `{"status":"ok"}`（C 是经隧道的 16017）。
  - 写一个一行一句的文件，跑 `NBIME --polish-test 文件 --levels 中中`，每句打一行 JSON，`note` 里写「整理好了」或者为什么退回原文。
- 小模型偶尔会加字、改字，客户端的检查不过关就输入原文。这是故意的，别为了「总是润色」把检查关掉。

## 第五步：交给用户

下面这些只有人能做。一次性列给用户，做完再回来看日志：

1. 打开 `~/Applications/NB 输入法.app`，跟着首次引导打开「麦克风」和「辅助功能」权限（系统设置 › 隐私与安全性）。拿到辅助功能权限后它会自己重启一次。
2. 走 C 直连局域网（不经 ssh）时，系统还会问「本地网络」权限。
3. 点到任意输入框，按住右 Option 说一句话，松开。菜单栏图标录音时变红，屏幕底部会冒出录音胶囊。

然后你看日志 `~/Library/Logs/NBIME.log`，一次正常的输入大致是这几行：

- 「启动 … → ws://…」
- 「辅助功能权限已有，开始监听热键」
- 「送出 …（麦克风名字）」
- 「结果 …」
- （开了润色时）「润色 …」
- 「输入 松开后 … 秒」

卡住时照这些对：

| 日志里看到 | 多半是 |
|---|---|
| 「按下没反应：没连上识别服务」 | 第二、三步没通：服务没起来、`tunnelHost` 没清空、或者 ssh 连不上 |
| 「隧道退出 … No route to host」 | 本地网络权限没给，或者 ssh 主机名不对 |
| 「没声音 …，不送去识别」 | 麦克风没声音：选错了设备、无线麦没开、合盖时内置麦被关掉。在「设置 › 通用 › 麦克风」里换一个 |
| 「焦点不在输入框」 | 粘贴那一刻焦点不在能打字的地方，正常现象，它会等你回去 |
| 什么都没有 | 辅助功能权限没给，或者重新编译以后授权掉了：在系统设置里把 NB 输入法关掉再打开 |

## 常见的坑

- 每次 `./build.sh` 都会把 `~/Applications` 里那份删掉重装（不带 `--no-run` 时还会重启它）；没签名的话辅助功能授权跟着掉。
- 识别模型在没人说话、或者人声很弱时，会把热词表当结果念出来，客户端已经拦了（`Settings.strippedEcho`）。你用 B 自己接模型时也会遇到，别以为是你的服务写错了。
- 「识别不准」先查收音：录音存在数据文件夹的 `recordings/`，历史页鼠标移上去能回听。声音太小，换什么模型都救不回来。
- 走 C 的 Windows 那边：Mac 上的 `unzip` 会弄坏中文文件名，要在 Windows 上用 `Expand-Archive` 解；PowerShell 5 只认带 BOM 的 UTF-8 脚本；`schtasks /end` 只结束主进程，重启前要把 `start_server` 全部结束；计划任务优先级设成 2。这些在 `server/README.md` 里都有详细的。
- `--demo`、`--test-file`、`--polish-test` 读的都是真实的 `config.json`；开着的隧道会借用，不会关掉。

## 搭好以后

- 让用户先用一天，再一起看 `~/Library/Logs/NBIME.log` 和历史里「改成了」的记录：哪些词老是错，加进热词，或者写成 `错的=对的`。
- 想改哪个功能，先翻 `docs/` 和 `git log`。每个决定为什么这么做、实测了什么，那里都写了。
- 这是你用户自己的输入法了，界面、快捷键、润色力度都可以按他们的习惯改。原作者的版本不接需求，不用往回提交。
