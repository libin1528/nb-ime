<p align="center">
  <img src="design/readme/icon.png" width="112" alt="NB 输入法图标">
</p>

<h1 align="center">NB 输入法</h1>

<p align="center">
  按住说话，松开输入。一款只为我自己的环境打造的 Mac 语音输入法。<br>
  <b>它不是拿来就用的产品，而是一份可以交给 AI 的上下文。</b>
</p>

<p align="center">
  <b>简体中文</b> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a>
</p>

<p align="center">
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white">
  <img alt="Swift / AppKit" src="https://img.shields.io/badge/Swift-AppKit-F05138?logo=swift&logoColor=white">
  <img alt="No dependencies" src="https://img.shields.io/badge/dependencies-none-34C759">
  <img alt="MIT" src="https://img.shields.io/badge/license-MIT-0A84FF">
</p>

<p align="center">
  <img src="design/readme/capsule-morph.gif" width="640" alt="录音胶囊：按下时长出来，边说边展开出字，松开后识别、输入，再缩回去">
</p>

## 软件要自己做

> 未来的工具不一定是一键安装的成品，而是一份可以交给 AI 的上下文。

做 NB 输入法有两个目标，分先后：

1. **首要：给自己打造一款最顺手的输入法。** 它只为我的环境服务：一台 Mac，加上局域网里一台带显卡的机器跑识别；说话中英混着来，常提到一堆自己项目里的专有名词。每一轮迭代都是因为我自己用着哪里不顺手，而不是为了把它变成一个值得发布的产品。我会一直按自己的想法改下去。
2. **其次：把做出来的东西当作上下文分享出来。** 拿去直接用多半跑不起来。但如果你也想做一款自己的语音输入法，可以把这个仓库交给你的 AI 编程工具（Claude Code、Codex、Cursor……），让它参照这里的决定、实测数据和踩过的坑，按**你的**环境做一个**你的**版本。

所以请把它当参考资料，而不是软件。

## 为什么不用现成的免费语音输入法

市面上免费的语音输入法已经很好用了，我还是自己搭了一套，原因有两个：

- **隐私。** 录音和文字只在自己家的局域网里走，不上传到任何人的服务器。
- **在我的工作环境里，自己搭的服务体验更好，也更稳定。** 识别跑在一台只为我服务的显卡机器上，不排队、不限流，也不受外网波动影响：松开后约 0.8 秒出完整结果，润色平均再加 0.6 秒。热词表里是我自己项目的名字，快捷键和润色力度也都按我的习惯调。

线上产品要服务成千上万的人，只能在规模、成本和体验之间找平衡，照顾大多数人的平均需求。NB 输入法不用做这道取舍题：它只服务我一个人，每个选择都只看我用着顺不顺手。

## 把它当上下文用

最省事的用法：clone 下来，打开你的 AI 编程工具，对它说：

```text
这个仓库是别人给自己做的 Mac 语音输入法。先读 README、docs/ 和 git log，
弄清楚每个功能为什么这么做、踩过哪些坑。然后帮我做一个适合我自己的版本：
识别想跑在 ____，我常说的语言是 ____，我最想要的功能是 ____。
```

推荐的阅读顺序，人和 AI 都适用：

| 先读 | 里面有什么 |
|---|---|
| [`docs/`](docs/) | 每一轮的开工单和记录：拍了什么板、实测的数据和结论、踩过的坑 |
| `git log` | 每一笔提交都写清改了什么、为什么改，连起来就是这个项目怎么一步步长出来的 |
| [`design/`](design/) | 交互稿，每一轮改前改后的截图，润色的前后对照页 |
| [`client-mac/Sources/`](client-mac/Sources/) | 按功能分文件的 Swift 代码，见下面的「可以借鉴什么」 |
| [`server/`](server/) | 服务端怎么部署、怎么开机自启，以及 Windows 上的坑 |

## 我的环境

先弄清它是照什么环境写的，才知道哪些要换成你自己的：

| | 我的 | 你多半要换掉 |
|---|---|---|
| 客户端 | macOS 26，原生 Swift / AppKit，常驻菜单栏，没有第三方依赖 | 系统版本（胶囊用了 Liquid Glass） |
| 识别 | 局域网里一台 Windows 显卡机器（RX 6700 XT），跑 [CapsWriter-Offline](https://github.com/HaujetZhao/CapsWriter-Offline) + Qwen3-ASR-1.7B | 识别跑在哪：本机、云端接口、别的模型 |
| 连接 | Mac 经 ssh 隧道连过去，录音不出家门 | 直连局域网，或者干脆不要服务端 |
| 润色 | 同一台机器上用 llama.cpp 跑 Qwen3.5-4B 8bit | 要不要润色、用哪个模型 |
| 说话习惯 | 中英混说，专有名词多，靠热词表兜着 | 你的语言、你的词表 |
| 界面语言 | 只有中文 | — |

## 可以借鉴什么

| 功能 | 代码 | 值得看的地方 |
|---|---|---|
| 录音胶囊 | [`Capsule.swift`](client-mac/Sources/Capsule.swift) | 系统的 `NSGlassEffectView`（clear 玻璃，文字下垫一层反色薄底）；从一颗圆长成胶囊，状态之间整块连续变形；波形跟着音量跳，说话时向上展开实时出字 |
| 全局快捷键 | [`Hotkey.swift`](client-mac/Sources/Hotkey.swift) | 用 CGEventTap 同时听键盘和鼠标：单按修饰键、F 键、鼠标侧键都能当快捷键，可以设两个；系统停用钩子后按实际按键状态重新对齐 |
| 流式预览 | [`AppController.swift`](client-mac/Sources/AppController.swift) | 同一段录音走两条 WebSocket：一条每 2 秒出一次预览，一条松开后出完整结果，用完整结果输入 |
| 热词按读音纠正 | [`Hotfix.swift`](client-mac/Sources/Hotfix.swift) | 模型写成「万三」，读音和热词「Wan3」一样就换回来；中文要声调也一样，挨着数字、量词的不换 |
| 识别后润色 | [`Polish.swift`](client-mac/Sources/Polish.swift) | 「去掉口误」「整理格式」各有关 / 中 / 强三档；不信任小模型的输出，过一遍「只删不加、热词都在」的检查，不过关就输入原文 |
| 菜单栏、设置、引导 | [`MenuBar.swift`](client-mac/Sources/MenuBar.swift) · [`SettingsWindow.swift`](client-mac/Sources/SettingsWindow.swift) · [`Onboarding.swift`](client-mac/Sources/Onboarding.swift) | 菜单栏图标本身就是状态：录音变红、识别中轮流亮、连不上变灰；所有配置都有界面 |

## 实测过的结论，踩过的坑

这些在代码里只是一两行，背后都是一次实测或者一次翻车，详细的在 [`docs/`](docs/) 和提交记录里：

- **服务端的音频缓存按连接分，不按任务分。** 预览和完整识别必须各开一条 WebSocket，挤在一条上录音会混在一起，完整结果变成空的。
- **人声太弱或者一直没说话时，识别模型会把提示里的热词表原样念出来。** 要检测出来，把热词倒过来排再认一遍复核。预览也会这样，可预览不带热词的话专有名词又会错，两头都得管。
- **预览的片段长度 2 秒是平衡点：** 比说话慢 1 到 1.5 秒；3 秒更准，但更新太慢。
- **`NSEvent` 的全局监听收不到单按的修饰键**，改用 CGEventTap。AI 模拟的按键会被系统丢掉，快捷键只能人手按，再看日志判断对不对。
- **重新编译以后「辅助功能」授权会丢**，用钥匙串里固定的开发证书签名就不丢；换 bundle id 也会丢。
- **clear 玻璃不垫底，浅色模式下深色背景上的字看不清。** `tintColor` 几乎不起作用，最后自己垫了一层反色薄底。
- **小模型润色偶尔会补字、改字。** 与其在提示词上死磕，不如在输出端做机械检查：加了字、丢了热词、删得太多、超时，一律退回原文。
- **llama.cpp 在 Windows 上不加 `--no-mmap`**，一个 4B 模型要占 5.7GB 内存，加了只占 834MB。

## 长什么样

<p align="center">
  <img src="design/readme/capsule-states.png" width="760" alt="胶囊的八个状态：正在听、边说边出字、说久了只留最后三行、识别中、已输入、没听到声音、没听清、连不上">
</p>

<p align="center">
  <img src="design/readme/settings-hotkey.png" width="560" alt="设置窗口的快捷键页：可以设两个快捷键，支持鼠标侧键">
</p>

<p align="center">
  <img src="design/polish/settings-before-after.png" width="760" alt="设置窗口改前改后：新加的「润色」页，去掉口误、整理格式各有关 / 中 / 强">
</p>

## 想自己跑一遍

<details>
<summary>需要一台带显卡的机器跑识别服务、macOS 26，以及自己编译。展开看步骤。</summary>

<br>

1. **服务端**：在一台有显卡的机器上装 CapsWriter-Offline 和 Qwen3-ASR 模型，见 [`server/README.md`](server/README.md)（我们的是 Windows）。识别后润色要再跑一个 Qwen3.5-4B，同一份说明里有；不跑也行，到「设置 › 润色」里把两项都关掉。
2. **客户端**：需要 macOS 26 和 Xcode 命令行工具。
   ```bash
   cd client-mac && ./build.sh
   ```
   装到 `~/Applications/NB 输入法.app` 并启动。想重编以后不用重新授权「辅助功能」，在 `client-mac/sign-identity.local` 里写一行你钥匙串里开发证书的名字；没有就用临时签名。
3. 第一次打开会引导你开麦克风和辅助功能权限；再到「设置 › 识别服务」里填你的 ssh 主机或服务器地址（默认值是照我们自己的机器写的）。

这是我自己的工具：不接需求，不承诺维护，issue 不一定回。更建议的做法是 fork 一份，或者让你的 AI 照着它重新写一个。

</details>

<details>
<summary>目录、本地数据和调试命令</summary>

<br>

| 目录 | 内容 |
|---|---|
| `client-mac/` | Mac 菜单栏客户端（Swift / AppKit，`Sources/` 下按功能分文件）。`./build.sh` 编译、装好并启动；`--no-run` 只装不启动，`--icon` 重画图标 |
| `server/` | 服务端（CapsWriter-Offline 和润色模型）的部署说明和 Windows 自启脚本 |
| `tools/` | 调试脚本，比如测流式预览的 `stream_test.py`、对比热词提示写法的 `hotword_echo_test.py` |
| `design/` | 交互稿 `mockup.html`，每一轮实际界面的对照截图，润色前后对照页 `polish/samples.html` |
| `docs/` | 每一轮的开工单和记录 |

客户端的本地数据都在 `~/Library/Application Support/NBIME/`：设置 `config.json`、热词 `hotwords.txt`、历史 `history.json`（最近 200 条），都能在设置窗口里改。日志在 `~/Library/Logs/NBIME.log`。

调试：

- `NBIME --test-file <音频>`：不用麦克风，按实时节奏走一遍同样的发送路径（含流式预览），打印 `PREVIEW` / `RESULT`。
- `NBIME --demo <界面>`：截图用，`listen` `quiet` `preview` `long` `think` `done` `miss` `offline` `morph`（录变形用的一整套）`menu` `onboarding` `settings:0`…`settings:6`。
- `NBIME --polish-test <文件>`：文件里一行一句，每句按润色的 8 种档位组合各跑一遍，一行一个 JSON（`--levels 中中,强强` 只跑这几种）。改提示词前后都跑一遍对比。
- 这几种模式会借用已经开着的隧道，不动它。

</details>

## 用到的开源项目

| 项目 | 用在哪 | 协议 |
|---|---|---|
| [CapsWriter-Offline](https://github.com/HaujetZhao/CapsWriter-Offline) | 识别服务端，客户端按它的 WebSocket 协议通信 | MIT |
| [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) | 语音识别模型（1.7B，q5_k 量化版随 CapsWriter 的模型包发布） | Apache-2.0 |
| [Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B) | 识别后润色的小模型（用 [unsloth](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF) 的 Q8_0 量化） | Apache-2.0 |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | 跑润色模型的 `llama-server`（用 CapsWriter 自带的 Vulkan 版） | MIT |
| [websockets](https://github.com/python-websockets/websockets)、[NumPy](https://github.com/numpy/numpy) | `tools/` 里的调试脚本 | BSD-3-Clause |

这些都没有打包进本仓库，要用的话按各自的协议去原项目下载。设计上参考了 Apple 的 Liquid Glass 和微信输入法的菜单。

## 协议

[MIT](LICENSE)。代码、文档、截图都可以随便拿去改，不用打招呼。
