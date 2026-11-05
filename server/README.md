# 服务端：ITX 上的 CapsWriter

识别跑在局域网里的 ITX（`itx-1.local`，RX 6700 XT 12GB），用的是 [CapsWriter-Offline](https://github.com/HaujetZhao/CapsWriter-Offline) v2.6 的服务端，模型 Qwen3-ASR-1.7B（q5_k）。音频编码器跑 ONNX CPU，文本解码走 Vulkan，AMD 显卡能用上；2026-11-05 实测识别子进程工作集约 1.3GB、专用显存约 1.8GB。CPU 忙仍会拖慢识别，见[满载实测](../docs/2026-11-05-itx-load-latency.md)。

## 现在的部署

| 项 | 值 |
|---|---|
| 目录 | `%USERPROFILE%\CapsWriter-Offline` |
| 模型 | `models\Qwen3-ASR\Qwen3-ASR-1.7B\` |
| 监听 | `127.0.0.1:6016`（只听本机，客户端走 ssh 隧道，防火墙没动；在外面怎么连见「在外面用」） |
| 自启 | 计划任务 `CapsWriterServer`，登录后启动，S4U 后台运行，挂了 1 分钟内重启，优先级 2（高于正常） |
| 日志 | `logs\server_latest.log`（INFO 级别会记下识别出的文字） |

对 `config_server.py` 的改动只有两处：`addr = '127.0.0.1'`、`enable_tray = False`。

识别的解码温度保持 CapsWriter 默认的 `0.4`（`core\server\engines\qwen_asr_gguf\asr_engine.py` 里 `decode_stream` 的默认值）。2026-10-29 试过改成 `0.0`（greedy）：同一段录音每次结果一样了（20 段录音各识别 3 次，改前 12 段三次一样、改后 20 段都一样），但随后出现 2 秒的音频要 10–90 秒才出结果，当时判断是 greedy 陷进重复循环，当天就改回去了。后来发现那段时间 ITX 上有重启留下的孤儿识别进程在占显存（见下面「常用操作」），慢的原因也可能是显存不够，温度 0 要在干净的环境里重测。备份 `asr_engine.py.bak-20261029` 就是原样。

## 从零部署

1. 在 Mac 上下载（ITX 直连 GitHub 只有约 240KB/s）：
   - `CapsWriter-Offline-20260914.zip`（v2.6 release，105MB）
   - `Qwen3-ASR-1.7B-q5_k.zip`（models release，1.9GB）
2. `scp` 到 ITX，解压：服务端解到用户目录 `%USERPROFILE%\`，模型解到 `CapsWriter-Offline\models\Qwen3-ASR\`。
   Mac 上的 `unzip` 会把包里的中文文件名弄坏，要在 ITX 上用 `Expand-Archive` 解。
3. 改 `config_server.py` 的上面两处。
4. 在 ITX 上以部署用户身份打开**管理员 PowerShell**，跑 `install-autostart.ps1`；它会写入识别映像的 IFEO 优先级，再注册并启动任务。

## 常用操作

```powershell
# 重启。schtasks /end 只结束主进程，识别子进程会留下来继续占着约 1.8GB 显存，所以要把 start_server 全部结束再启动
schtasks /end /tn CapsWriterServer; Get-Process start_server -ErrorAction SilentlyContinue | Stop-Process -Force; schtasks /run /tn CapsWriterServer
Get-Process start_server   # 正常是 3 个：主进程加两个子进程。多了就是之前留下的孤儿进程
Get-Content -Tail 20 -Encoding UTF8 %USERPROFILE%\CapsWriter-Offline\logs\server_latest.log
```

### 进程优先级

计划任务不写优先级时默认是 7，起来的进程是「低于正常」（BelowNormal）：CPU 抢不过同一台机器上的别的程序。ITX 上跑 Flutter 测试那种重活时识别会变得很慢，闲了几分钟后的第一句尤其慢（10-29 14:19 一段 2 秒的预览要 38 秒）。所以两个任务都设成优先级 2（高于正常），两个注册脚本里写了 `-Priority 2`。已经注册好的任务可以直接改：

```powershell
foreach ($n in "CapsWriterServer","NBPolishLLM") { $t = Get-ScheduledTask -TaskName $n; $t.Settings.Priority = 2; Set-ScheduledTask -InputObject $t }
```

改完要重启服务才生效。Windows 不默认继承父进程的 AboveNormal，单靠任务 Priority 2，识别的两个子进程仍会回到 Normal。2026-11-05 已采用 IFEO 注册表设置：

`HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\start_server.exe\PerfOptions` 下，`CpuPriorityClass` 为 **DWORD 6（AboveNormal）**。这是 IFEO 的编号，不是计划任务的 Priority 2。主进程和两个子进程的实际映像名都是本项目的 `start_server.exe`，新建进程即生效；不使用启动包装脚本。实测与回归见[调查记录](../docs/2026-11-05-itx-load-latency.md)。

`install-autostart.ps1` 需要管理员权限，幂等地只设置 `CpuPriorityClass`，保留同键的其它值；注册表写入失败时先停止安装，不打断正在运行的服务。IFEO 按映像名匹配，不按安装路径匹配；若以后有其它无关软件也叫 `start_server.exe`，先处理命名冲突，不向 `python.exe` 等通用解释器设置此项。llama-server 和转写服务的任务及参数不变。CPU 优先级不等于内存优先级，不能保证工作集不被换出。

检查（管理员 PowerShell；进程检查也可普通权限执行）：

```powershell
$key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\start_server.exe\PerfOptions'
Get-ItemProperty -Path $key -Name CpuPriorityClass   # 应为 6
(Get-Item $key).GetValueKind('CpuPriorityClass')    # 应为 DWord
Get-Process start_server | Select Id, Path, PriorityClass   # 应为三个 AboveNormal
Get-Process llama-server | Select Id, PriorityClass        # 保持 AboveNormal
```

撤销（管理员 PowerShell）：这次新建的 `PerfOptions` 里只有这一项，可删整个键，再按上面的「常用操作」重启 CapsWriter；主进程仍由任务设为 AboveNormal，子进程恢复 Normal。**若以后加入了其它值，只删除 `CpuPriorityClass`，保留其它值**，也不要删除映像键下其它 IFEO 配置。以后再运行安装脚本会重新启用这一项。

```powershell
$key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\start_server.exe\PerfOptions'
Remove-Item -Path $key   # 确认只有 CpuPriorityClass 时执行；有子键会要求确认
# 若已有其它值，改为：Remove-ItemProperty -Path $key -Name CpuPriorityClass
schtasks /end /tn CapsWriterServer
Get-Process start_server -ErrorAction SilentlyContinue | Stop-Process -Force
schtasks /run /tn CapsWriterServer
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

## 给 ClawChat 用的转写接口

ClawChat 的语音输入只会说 OpenAI 的 `POST /v1/audio/transcriptions`，CapsWriter 是自有协议（下面「协议」一节），`transcribe_api.py` 在中间转一道：收 multipart 里的音频，用 ffmpeg 解成 16kHz 单声道 float32，按 Mac 客户端完整识别那一路的参数（分段 60 秒、重叠 4 秒）送给 CapsWriter，回 `{"text": ...}`。NB 输入法自己不走它。只用 Python 标准库，不用 pip。

| 项 | 值 |
|---|---|
| 目录 | `%USERPROFILE%\nb-transcribe`（`transcribe_api.py`、`ffmpeg.exe`、`install-transcribe.ps1`） |
| 监听 | `127.0.0.1:6018`，客户端的 ssh 隧道把本机 16018 转过来 |
| 接口 | `POST /v1/audio/transcriptions`（字段 `file` 必填，`model` 随便填，`prompt` 当热词 `context`，`language` 填 `zh` / `en` 这类代码或不填 = 自动，`response_format` 支持 `json` / `text` / `verbose_json`）；`GET /v1/models` 只有一个 `qwen3-asr-transcribe`，名字带 transcribe，ClawChat 按名字认出来；`GET /health` |
| 鉴权 | 不看 `Authorization`，ClawChat 里 API Key 随便填。服务只听本机，能进来的都是走 ssh 隧道的 |
| 自启 | `install-transcribe.ps1` 注册计划任务 `NBTranscribeAPI`，和识别服务一样 |
| 日志 | `nb-transcribe\server.log`，每次记音频时长、解码和识别各花多久、识别出的字 |
| 速度 | 2 秒的 m4a 0.3 秒回来，74 秒的 5 秒（2026-11-03 实测，经隧道） |

部署（识别服务已经装好的前提下）：

1. 准备 Python 3.9 以上（ITX 上是 3.12）和一个 Windows 版 ffmpeg.exe。ITX 直连 GitHub 慢，在 Mac 上下 [gyan.dev](https://www.gyan.dev/ffmpeg/builds/) 的 `ffmpeg-release-essentials.zip` 再 `scp`。ITX 上用的是机器上 DeepCool 软件自带的那份（同样是 gyan.dev 的 7.1 full build）拷过来的。
2. 把 `transcribe_api.py`、`install-transcribe.ps1`、`ffmpeg.exe` 放进 `%USERPROFILE%\nb-transcribe\`，以登录用户身份跑：`powershell -NoProfile -ExecutionPolicy Bypass -File install-transcribe.ps1`。最后打出 `Running` 和型号列表就是起来了。
3. 试一下（Mac 上，NB 输入法开着时它的隧道已经带了 16018）：

   ```sh
   curl -s 127.0.0.1:16018/v1/audio/transcriptions -F file=@a.m4a -F model=qwen3-asr-transcribe -F language=zh -F "prompt=ClawChat，ClawNest"
   ```

ClawChat 里填的服务地址：

- Mac：`http://localhost:16018/v1`。NB 输入法开着就有这条隧道；没开的话自己开一条 `ssh -N -L 127.0.0.1:16018:127.0.0.1:6018 winrig`。
- Android 真机：在插着手机的那台机器上开同样一条隧道，再 `adb reverse tcp:16018 tcp:16018`，手机里也填 `http://localhost:16018/v1`。

只转一道，不做 NB 输入法客户端那些检查：人声太弱时 Qwen3-ASR 会把 `prompt` 原样抄出来，念一串热词时会顺着热词表往下背（见下面「协议」），这两种要调用方自己防。

```powershell
schtasks /end /tn NBTranscribeAPI; schtasks /run /tn NBTranscribeAPI   # 重启
Get-Content -Tail 20 -Encoding UTF8 %USERPROFILE%\nb-transcribe\server.log
```

## 在外面用

客户端连 ITX 一直是经 ssh 隧道（「设置 › 连接」里的 SSH 主机，默认 `winrig`），识别、润色、转写三个端口走同一条隧道。ITX 上的服务都只听本机，没对局域网或公网开端口。

2026-11-02 起 `~/.ssh/config` 会按在不在办公室自动选路：在办公室走局域网 `itx-1.local`，在外面走公网端口映射（`Match originalhost winrig … !exec at-office.sh`，那份配置不在这个仓库里）。所以客户端这边什么都不用设，在外面照样能用。2026-11-03 在办公室里用 `CLAWCHAT_FORCE_REMOTE=1` 强制走公网那条测过：识别握手、润色、转写都通，往返 20 毫秒上下。

客户端会在换了网络（离开办公室、换 Wi-Fi、合盖后在别处打开）和睡眠唤醒以后马上重开隧道，让 ssh 重新选路；不重开的话，旧隧道要等保活两次没回（约 30 秒）才断，这段时间按住说话没反应。正在说话、等结果或者润色的时候先不动，最多等 30 秒。日志里记「网络变了」「换了网络，重开隧道」。

「局域网直连」那种方式（不经 ssh）在外面用不了，服务端也不该对公网开放。

## 协议

客户端与服务端之间是 WebSocket 文本帧（子协议 `binary`），格式见 CapsWriter 的 `core/protocol.py`：

- 客户端 → 服务端：`{task_id, source:"mic", data, is_final, time_start, seg_duration, seg_overlap, context, language}`，`data` 是 16kHz 单声道 float32 的 base64；最后一帧 `data` 为空、`is_final` 为 true。
- 服务端 → 客户端：`{task_id, is_final, text, ...}`。
- `context` 是热词提示。人声太弱时 Qwen3-ASR 会把它原样抄出来，客户端有检测与倒序复核（见 `tools/hotword_echo_test.py`）；念一串名字、头一个是热词时它会顺着热词表往下背，客户端发现连着一串热词就不带热词重认（见 `docs/2026-11-02-hotword-run.md`）。
- 多个客户端可以同时连，服务端单模型排队，按连接轮转。
