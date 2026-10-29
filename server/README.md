# 服务端：ITX 上的 CapsWriter

识别跑在局域网里的 ITX（`itx-1.local`，RX 6700 XT 12GB），用的是 [CapsWriter-Offline](https://github.com/HaujetZhao/CapsWriter-Offline) v2.6 的服务端，模型 Qwen3-ASR-1.7B（q5_k）。解码走 Vulkan，AMD 显卡能用上，显存约 1.6GB，进程内存几十 MB。

## 现在的部署

| 项 | 值 |
|---|---|
| 目录 | `%USERPROFILE%\CapsWriter-Offline` |
| 模型 | `models\Qwen3-ASR\Qwen3-ASR-1.7B\` |
| 监听 | `127.0.0.1:6016`（只听本机，客户端走 ssh 隧道，防火墙没动） |
| 自启 | 计划任务 `CapsWriterServer`，登录后启动，S4U 后台运行，挂了 1 分钟内重启 |
| 日志 | `logs\server_latest.log`（INFO 级别会记下识别出的文字） |

对 `config_server.py` 的改动只有两处：`addr = '127.0.0.1'`、`enable_tray = False`。

## 从零部署

1. 在 Mac 上下载（ITX 直连 GitHub 只有约 240KB/s）：
   - `CapsWriter-Offline-20260914.zip`（v2.6 release，105MB）
   - `Qwen3-ASR-1.7B-q5_k.zip`（models release，1.9GB）
2. `scp` 到 ITX，解压：服务端解到用户目录 `%USERPROFILE%\`，模型解到 `CapsWriter-Offline\models\Qwen3-ASR\`。
   Mac 上的 `unzip` 会把包里的中文文件名弄坏，要在 ITX 上用 `Expand-Archive` 解。
3. 改 `config_server.py` 的上面两处。
4. 在 ITX 上跑 `install-autostart.ps1`。

## 常用操作

```powershell
schtasks /end /tn CapsWriterServer; schtasks /run /tn CapsWriterServer   # 重启
Get-Content -Tail 20 -Encoding UTF8 %USERPROFILE%\CapsWriter-Offline\logs\server_latest.log
```

## 润色用的小模型

识别结果粘贴前，客户端会把文字交给 ITX 上的小模型整理一遍（去口误、整理格式）。用的是 CapsWriter 自带的 llama-server（Vulkan 版，`core\server\engines\llama\bin\`），不用另装运行时。

| 项 | 值 |
|---|---|
| 目录 | `%USERPROFILE%\nb-llm` |
| 模型 | `Qwen3.5-4B-Q8_0.gguf`（unsloth 的量化，4.5GB；在 Mac 上下好 scp 过去） |
| 监听 | `127.0.0.1:6017`，客户端的 ssh 隧道把本机 16017 转过来 |
| 占用 | 显存约 5GB（加上识别一共约 7GB / 12GB）；`--no-mmap` 以后进程内存不到 1GB |
| 自启 | `install-polish.ps1` 注册计划任务 `NBPolishLLM`，和识别服务一样 |
| 日志 | `nb-llm\server.log` |

选型实测（15 条真实口语 × 8 种档位组合）：Qwen3.5-4B 4bit 每秒约 90 token、出错多一些；8bit 平均 0.83 秒、最长 2.3 秒（270 字的长段），120 次里 1 次没过客户端检查；Qwen3.5-9B 慢一倍、规则执行并不更稳；Qwen3-4B-Instruct-2507 更容易删多。

部署（识别服务已经装好的前提下）：

1. 在 Mac 上从 Hugging Face 下 [`unsloth/Qwen3.5-4B-GGUF`](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF) 里的 `Qwen3.5-4B-Q8_0.gguf`，`scp` 到服务端机器的 `%USERPROFILE%\nb-llm\`。
2. 把 `install-polish.ps1` 拷到服务端机器上，以登录用户身份跑：`powershell -NoProfile -ExecutionPolicy Bypass -File install-polish.ps1`。最后打出 `Running` 和 `{"status":"ok"}` 就是起来了。
3. 客户端不用改：ssh 隧道会多转发一个端口，连上以后「设置 › 润色」页底下的点变绿。不想跑这个模型，就在那一页把两项都关掉。

坑：

- 脚本里有中文，Windows 自带的 PowerShell 5 只认带 BOM 的 UTF-8，存的时候别把 BOM 去掉，不然整份解析失败。
- 经 ssh 跑的时候 `USERDOMAIN` 是 `WORKGROUP`，注册计划任务会报「No mapping between account names and security IDs」，所以脚本里账户写成 `机器名\用户名`。
- 不加 `--no-mmap` 时模型文件整份映射进内存，进程占 5.7GB；机器内存紧（比如开着 WSL）就会挤。

```powershell
schtasks /end /tn NBPolishLLM; schtasks /run /tn NBPolishLLM   # 重启
Get-Content -Tail 20 %USERPROFILE%\nb-llm\server.log
```

## 协议

客户端与服务端之间是 WebSocket 文本帧（子协议 `binary`），格式见 CapsWriter 的 `core/protocol.py`：

- 客户端 → 服务端：`{task_id, source:"mic", data, is_final, time_start, seg_duration, seg_overlap, context, language}`，`data` 是 16kHz 单声道 float32 的 base64；最后一帧 `data` 为空、`is_final` 为 true。
- 服务端 → 客户端：`{task_id, is_final, text, ...}`。
- `context` 是热词提示。人声太弱时 Qwen3-ASR 会把它原样抄出来，客户端有检测与倒序复核（见 `tools/hotword_echo_test.py`）。
- 多个客户端可以同时连，服务端单模型排队，按连接轮转。
