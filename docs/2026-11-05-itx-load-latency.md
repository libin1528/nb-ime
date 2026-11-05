# 2026-11-05 ITX 忙时语音输入延迟

## 现象与结论

ITX 上的 CPU 工作会拖慢语音输入，显卡空着也不能避免。识别并不是全程 GPU：CapsWriter 的 Qwen3-ASR **音频编码器跑 CPU，GGUF 文本解码才跑 Vulkan**。初查时识别子进程实际是 Normal，会和编译、测试抢时间；润色的影响小得多。11:00 已按用户决定用 IFEO 注册表永久设置为 AboveNormal，重启后主进程和两个子进程均已生效。转写接口还有启动 ffmpeg 的额外开销，NB 输入法自己不经过这一层。

首次调查先临时改变运行参数、优先级和实验负载亲和性，完成后恢复。随后用户选择注册表方案，已永久采用；没有重新注册计划任务，没有改其它项目，也未编译 Mac 客户端或提交、推送。

## 机器与服务现状

2026-11-05 10:41～10:42（北京时间）初始快照：

- Ryzen 5 7500F，6 个物理核、12 个逻辑处理器；Windows 可用物理内存总量 15.62GiB。
- CPU 2%～5%，可用内存约 9.4GiB；系统提交约 22.2GiB / 27.6GiB。页文件分配 12,257MiB，已用 3,033MiB，历史峰值 6,135MiB。
- 有 `wslservice.exe`、`vmcompute.exe`，`wsl --list --running --quiet` 为空，没有 `vmmem`、Docker 工作进程。不能把当时的常驻内存归因于运行中的 WSL。
- 常驻工作集最大的项目进程是 ASR 子进程约 1.26GiB；还有 Defender、Edge、系统服务等。三个 `start_server`，没有多余识别孤儿。

| 进程 | PID | 实际 PriorityClass | 线程 | 工作集 | Private Bytes |
|---|---:|---|---:|---:|---:|
| CapsWriter 主进程 | 4132 | AboveNormal | 14 | 19.7MiB | 410MiB |
| multiprocessing 辅助子进程 | 3224 | Normal | 15 | 4.3MiB | 399MiB |
| ASR 推理子进程 | 17652 | Normal | 24 | 1,289MiB | 4,303MiB |
| llama-server | 44592 | AboveNormal | 17 | 144MiB | 7,549MiB |
| transcribe_api.py | 45264 | AboveNormal | 1 | 5.0MiB | 16.6MiB |

三个计划任务都是 Running、`Settings.Priority=2`。所有服务亲和性都是 `0xFFF`，允许用全部 12 个逻辑处理器。llama 日志显示推理线程池 `n_threads=6`，这与进程总线程数 17 是两回事；没有显式设置 `--threads`、`--threads-batch`、`--prio`、`--poll`。

Windows 并不默认把 AboveNormal 传给新子进程：没有显式指定时一般回到 Normal，BelowNormal / Idle 才特殊继承。[Microsoft 的调度说明](https://learn.microsoft.com/en-us/windows/win32/procthread/scheduling-priorities)与现场结果一致。现已按用户选择用 IFEO `start_server.exe\PerfOptions` 的 DWORD `CpuPriorityClass=6` 设置每个新进程的 AboveNormal；不使用启动包装脚本。

### 内存是否被换出

初始采样 `PagesInput/sec=0`、`PageReads/sec=0`。小工作集、较大 Private Bytes 和页文件历史用量说明需要留意内存，但不能用 `Private Bytes - Working Set` 计算“本进程被换出多少”：GPU 驱动的提交、非驻留页也在里面。GPU 计数器另见 ASR 专用显存约 1.81GiB、共享约 12MiB；llama 专用约 4.57GiB、共享约 662MiB。

实验开始后，其它会话在 `C:\dev\clawchat-tip`、`clawchat-tip-2` 启动真实 Flutter 测试。10:45 快照 CPU 84%、可用内存 3,964MiB、提交约 27.2GiB / 28.6GiB；两个 `dartaotruntime` 各占约 1.5GiB，还有许多 `flutter_tester`。后续原配置满载轮可用内存最低 2,300MiB，系统 `PagesInput/sec` 峰值 16,856、`PageReads/sec` 峰值 804。**内存压力和磁盘回读确实同时存在，但本次没有按进程采集硬缺页 ETW，不能把这些读盘全部归到模型。** 未停止或修改这些其它项目的工作。

另用 `GetProcessInformation(ProcessMemoryPriority)` 实测三个 CapsWriter 进程及 llama 均为 **5（Normal）**。CPU PriorityClass 与页回收用的 MemoryPriority 是两套设置；不能说“计划任务 Priority 2 就保证模型不会被换出”。[Microsoft 的内存优先级说明](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/ns-processthreadsapi-memory_priority_information)。

## 历史日志

只读 `~/Library/Logs/NBIME.log`，统计范围 10-28 15:48:15～11-05 10:34:22；包含日常使用、手工测试和重认，不能当成纯线上样本。分位数用 nearest rank，P50 用中位数。

| 日志阶段 | 数量 | P50 | P95 | P99 | 最大 | 超过 3 秒 |
|---|---:|---:|---:|---:|---:|---:|
| `结果 … 松开后` | 1,935 | 444ms | 1,432ms | 2,877ms | 11,133ms | 16 |
| 有耗时的 `润色` | 1,712 | 460ms | 1,030ms | 1,880ms | 10,780ms | 6 |
| `输入 松开后` | 1,736 | 920ms | 2,237ms | 3,619ms | 13,249ms | 30 |

另有 **4 条识别超时**（10-29 一条、11-04 两条、11-05 一条），不在成功返回的分位数里。当前客户端的“松开后”计时从发完 final 帧开始，热键松开到 `送出` 常另有约 0.32 秒；表中不是完整按键到输入耗时。

值得定位的时段：

- 10-29 11:37～11:38：7.4 秒录音等 11,133ms；2.5 秒录音等 4,362ms，润色还出现 3 秒超时。
- 10-29 14:19～14:20：先识别超时，随后 2.1 秒录音等 6,952ms；再下一句 9.1 秒录音只等 893ms。录音长度本身解释不了这一尖峰。
- 10-30 09:30：3.7 秒录音识别 7,091ms，润色 3.05 秒超时。
- 11-04 17:25：识别超时后，9.6 秒录音等 7,186ms，润色只花 0.80 秒。
- 11-02 16:58～17:02 的多个 4.7～8.8 秒结果，是同一段 41.5 秒录音触发“热词连成一串”后**重认**的测试，不能直接拿来证明 CPU 饥饿。历史缺少同时间的 ITX 性能记录，也不能把每次尖峰都追溯成同一个原因。
- 11-05 截止上述时间：89 个结果，P50 443ms、P95 983ms；81 次润色，P50 440ms、P95 810ms。

## 可控实验

借用 NB 输入法已有的 ssh 隧道，没有重开或修改它：Mac `16016 → 6016`、`16017 → 6017`、`16018 → 6018`，三者同一 ssh 进程。每次请求独立串行，避免本次识别与润色互相争显卡。

- 音频固定为本机已有的 `recordings/20261105-103007-576B8D7F.wav`，3.196875 秒、16kHz 单声道；不更改原文件。
- **直接识别**：复用 `server/transcribe_api.py` 的 WebSocket 客户端，Mac 预先转好 float32，直接发 `16016`；`seg_duration=60`、`seg_overlap=4`、`language=chinese`、无热词，无流式预览。更接近 NB 输入法的服务路径，但不是完整 UI 延迟。
- **转写**：`curl -F file=@… -F model=qwen3-asr-transcribe -F language=zh http://127.0.0.1:16018/v1/audio/transcriptions`，包含 Windows ffmpeg、HTTP 和识别。
- **润色**：固定 system 要求只去口误补标点；user 为“呃我们今天下午开个会把把这个上线的事情定下来你看行不行”；`temperature=0`、`max_tokens=128`、`cache_prompt=true`、`enable_thinking=false`，发 `16017/v1/chat/completions`。这是短请求探针，不冒充客户端完整 few-shot 提示词的延迟。
- **健康检查**：`16018/health`，不跑模型，用来观察隧道和 HTTP 调度。
- **CPU 负载**：单个临时 PowerShell 进程内起 12 个 C# 工作线程，只做数值循环，Normal 优先级；每个线程用 Stopwatch 按墙钟 **75 秒自行结束**，控制进程等待清理。后续成对实验最长 90 秒。没有主动制造内存或磁盘负载；真实测试仍会产生自己的 I/O。
- 每种顺序测试 10 次，保留第一次冷请求；HTTP 单次上限 15 秒。CPU、运行队列、可用内存、页回读每约 3～4 秒采样。后续有互斥锁避免压测重叠。一轮早期 High 试测与上一轮尾部重叠，**整轮作废，表中只列独立重跑**。

### 空闲与满载

数值为 **P50 / 最大值（ms）**；每格 10 次全部成功。10 样本的 nearest-rank P95 就是最大值，不应理解为长期尾延迟保证。

| 条件 | 直接识别 | 转写接口 | 润色 | 隧道健康检查 |
|---|---:|---:|---:|---:|
| 初始空闲，CPU 2%～5% | 未测 | 395 / 762 | 260 / 643 | 10 / 15 |
| 无人工负载，但真实 Flutter 测试已运行 | 601 / 710 | 520 / 557 | 283 / 292 | 12 / 14 |
| 12 线程满载，原配置 | 1,209 / 1,442 | 1,651 / 2,273 | 322 / 335 | 81 / 142 |
| 同样满载，CapsWriter 全部进程和 llama 临时 High | 778 / 909 | 1,174 / 1,444 | 327 / 385 | 94 / 164 |
| 同样满载，仅 llama 改为 2 线程、关闭 polling，其余恢复原配置 | 1,113 / 1,219 | 1,352 / 1,552 | 394 / 652 | 87 / 114 |
| 实验负载只占 4 核 8 线程，服务保持原配置 | 683 / 727 | 632 / 768 | 353 / 569 | 20 / 40 |

最初一次满载（还未加入直接 WebSocket 探针）转写为 **1,871 / 2,406ms**、润色 **342 / 449ms**，与第二轮方向一致。独立轮次中真实测试的负载和内存会变化，High 的百分比只能作现场参考，下面再做同一轮内的交替验证。

转写服务日志能拆开 ffmpeg 和模型：初始热请求解码约 **0.03 秒**、识别 **0.24～0.27 秒**；首轮满载解码 **0.46～1.04 秒**、识别 **0.76～1.21 秒**。因此接口 1～2 秒不能全部记在模型上，NB 输入法不会承担 ffmpeg 这部分。

满载时 ITX 本机 Python 连 `/health`：6018 中位数约 **3.9ms**（最大 18.4ms），6017 热请求多为 **0.37～0.43ms**；同期 Mac 经 ssh 的 6018 健康检查约 **80～100ms**，TCP 连接本机监听只花约 0.2ms。说明 Windows 侧 ssh / 转发调度也变慢了，但不足以解释识别多出的整秒，更不支持“只修隧道就行”。

## 原因

1. ITX 的 `config_server.py → Qwen3ASRGGUFArgs` 明确是 `onnx_provider='CPU'`、`llm_use_gpu=True`。`inference/encoder.py` 创建两个 ONNX CPU Session，音频特征、编码都在文本解码前；没有 GPU 结果可供解码时，显卡只能等。该文件已关闭 ONNX spinning，不应再把它当成未关闭自旋的问题。未设置 intra-op 线程上限时 ONNX 默认按物理核建线程池，见 [ONNX Runtime 线程说明](https://onnxruntime.ai/docs/performance/tune-performance/threading.html)。
2. 原配置真正做编码的 Normal 子进程与许多测试线程同级，运行队列可到几十条。计划任务 Priority 2 只提高了主进程，未覆盖这一段；现已由 IFEO 补齐。
3. Vulkan 解码和润色仍需 CPU 提交 GPU 工作、分词、采样、HTTP 处理；它们的 GPU 核心没被编译占用，也不能完全脱离 CPU 调度。现场润色的增加只是几十毫秒，主要矛盾在识别。
4. 16GB 机器同时跑两套测试，系统提交接近上限且有硬缺页读盘，会扩大尾延迟。显卡私有显存还够，并不等于系统内存也够。

## 试过什么与已采用的修法

### 已采用：IFEO 永久设置 AboveNormal

为排除独立轮次背景工作变化，再做一轮 **90 秒、始终 CPU 100%** 的交替对照：只改 CapsWriter 两个子进程，主进程和 llama 保持原始 AboveNormal，亲和性保持不变。顺序为 Normal → AboveNormal → High → Normal → AboveNormal → High，每段 15 秒；直接 WebSocket 连续送同一音频。切换后前 4 秒、跨段请求及段尾请求不计入稳定样本，避免切换边界误归类。

| ASR 子进程 PriorityClass | 稳定样本数 | 直接识别 P50 | 最大 |
|---|---:|---:|---:|
| Normal | 11 | 1,109ms | 1,336ms |
| AboveNormal | 14 | 753ms | 885ms |
| High | 12 | 763ms | 816ms |

**AboveNormal 比 Normal 的中位数减少约 32%，High 没有进一步降低中位数。** 这一轮可用内存仍在 2,607～4,752MiB 变化，故这是短录音现场对照，不承诺任意负载下的最大延迟。High 会更强地挤占系统线程，首选只补齐项目识别子进程的 AboveNormal。没有采用 High 或 Realtime，永久部署采用下述 IFEO 设置。

用户决定采用注册表而非启动包装脚本。11-05 10:58 先查 SSH 会话：`itx-1\itx` 已具备管理员权限，64 位 PowerShell；确认三个进程映像均为 `C:\Users\qyqx1\CapsWriter-Offline\start_server.exe`，目标 `PerfOptions` 原先不存在，没有覆盖其它值。随后创建：

`HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\start_server.exe\PerfOptions`，DWORD **`CpuPriorityClass=6`**。

这是 IFEO 编号，与计划任务 Priority 2 不同。停止 CapsWriter 任务、结束所有本项目 `start_server`，再启动原任务；约 **23.7 秒**确认三个进程及 6016 监听就绪。没有用 `SetPriorityClass` 补设运行中优先级，所以重启后的 AboveNormal 是注册表生效的证据。所有其它 IFEO 项、llama 和转写任务都未改。

`server/install-autostart.ps1` 已加入同一设置，只写 `CpuPriorityClass`，保留其它值；管理员要求和注册表写入放在停止现有服务之前，失败不打断服务。文件保存为带 BOM 的 UTF-8，兼容 Windows PowerShell 5。经 ITX PowerShell 解析无错误，且从安装脚本提取的真实注册表代码连续执行两次，结果仍为唯一的 DWORD `CpuPriorityClass=6`。未在 ITX 执行整个安装脚本，任务定义未重新注册。查询和撤销（删本次新建的 `PerfOptions` 键，若以后有其它值则只删 `CpuPriorityClass`）统一见 [server/README.md「进程优先级」](../server/README.md#进程优先级)。

### 润色减少线程、关闭轮询：本次不采用

临时停 `NBPolishLLM`，按原任务参数启动一个试验进程，额外加 `--threads 2 --threads-batch 2 --poll 0 --poll-batch 0`，保持 AboveNormal。模型健康检查后才开始压测；自动清理实验进程，再用原计划任务启动服务并等健康检查成功。

润色 P50 **394ms**，原满载轮 **322ms**；包括首个冷请求的最大值为 652ms。即使去掉第一次冷请求，P50 仍约 393ms。**但不能据此判定新参数使推理变慢**：请求相同，重启前模型输出 15 个 token，实验进程及恢复后的原进程均输出 19 个 token；有输出内容、缓存或重启状态的干扰。响应 `timings.predicted_per_token_ms` 的热请求中位数，原满载轮为 **15.34ms/token**、新参数 **15.11ms/token**；prompt 时间分别约 42.5 / 43.4ms，基本相同。初始空闲也是约 15.10ms/token，说明润色的 GPU 解码本身受 CPU 满载影响很小。

这个组合没有显示出足以采用的速度收益，不写进安装脚本。它同时改了线程数和 polling，不能据此评价每个单独参数；也没必要继续在用户正在使用的机器上扩大参数搜索。`--prio` / `--prio-batch` 没有另做启动参数试验，运行时 High 对照已经显示润色不是主要瓶颈。参数含义以 ITX 这份二进制的 `--help` 为准，不能照其它版本的默认值套用。

### 给后台工作留资源

另做 75 秒对照：只让本次人工负载用 8 个线程，亲和性 `0x0FF`；服务仍允许全部核，保持原始优先级。`GetLogicalProcessorInformation` 查得这台机器六个物理核的逻辑掩码依次为 `3 C 30 C0 300 C00`，所以这确实把最后两个物理核留给负载之外的工作；没有改真实 Flutter 测试的亲和性。

直接识别 P50 **683ms**、转写 **632ms**、隧道健康检查 **20ms**；相对全核人工负载轮的 1,209 / 1,651 / 81ms，分别减少约 44% / 62% / 76%。润色 P50 353ms，仍没有明显改善。这轮其它项目仍用其它核，整机 CPU 86%～100%（中位数 98%），并不是两个核一直空闲。这个试验减少了人工负载的并行能力，不是“满吞吐不付代价”的优化；它说明**后台任务限制并行、留出 CPU 余量比只调 llama 参数更有价值**。其它项目的负载和内存会变动，独立轮次的百分比不作为严格收益保证。

优先处理实际测试入口的并行度和内存峰值：本次观察到两套 Flutter 测试同时跑，不能只给其中一套限线程。后台工作可从 BelowNormal 启动，让输入法、ssh 和系统先得到 CPU；编译／测试的并行度、WSL／Docker 的内存上限由各自入口控制。当前没有运行中的 WSL，不建议为了这次延迟去停止 WSL 服务。真实项目的入口和配置本次都没动。

不要用 `--no-mmap` 或 CPU High 当成内存驻留保证，也不要在低内存时靠加模型线程解决问题。若保留当前并行工作规模，需另做容量规划；本次没有制造额外内存或磁盘压力。

### 后续可测，但尚未验证

- ASR 的 ONNX 编码器切到 DirectML，可以从根源减少编码 CPU 竞争；需要先确认打包的 ONNX Runtime 有 DML Provider，再测短句固定 padding、识别结果和 GPU 与润色争用。现在配置为 CPU，仅改一个字符串不保证真正启用 DML，不能直接当成已验证修法。
- 若剩余约 0.1 秒的隧道调度延迟仍重要，再在独立实验中研究项目隧道对应的 Windows ssh 子进程；本次没有提高或修改全局 ssh 服务。

## 注册表方案回归与收尾

首次调查 10:54～10:55 已清理全部临时负载并恢复参数；以下是用户决定永久采用后的状态。

### 11:00～11:02 回归

沿用上次同一音频、WebSocket／转写请求及固定润色请求，每项 6 次；12 线程 Normal CPU 数值负载缩短为 **40 秒**，线程按墙钟自行结束。保留第一条冷请求，不删异常值。两轮各 24 个响应全部成功，直接识别文字一致；润色均为 19 个输出 token，本轮两种条件的长度可比。

| 本轮条件 | 直接识别 P50 / 最大 | 转写 P50 / 最大 | 润色 P50 / 最大 | 隧道健康检查 P50 / 最大 |
|---|---:|---:|---:|---:|
| 无人工负载 | 616 / 1,719ms | 528 / 1,150ms | 344 / 533ms | 11 / 12ms |
| 40 秒 CPU 满载，IFEO 已生效 | 739 / 778ms | 1,108 / 1,257ms | 367 / 390ms | 91 / 95ms |

本轮“无人工负载”前 CPU 仍为 86%、可用内存 4,738MiB，有其它测试工作，**未获得严格空闲条件**，没有为凑空闲数据停止无关进程。首条识别包含重启后的冷开销；其余直接识别约 605～621ms、转写约 520～571ms。初次调查的严格空闲基线仍见前表，不能把本轮背景条件伪称相同。

与首次独立 Normal 满载轮相比，直接识别 P50 **1,209 → 739ms（约减少 39%）**，转写 **1,651 → 1,108ms（约减少 33%）**，与之前同轮交替试验的方向一致。轮次间背景测试、内存状态不同，百分比作现场参考。润色 **344 → 367ms**，服务未修改，正常返回；本轮没有出现超时。

### 最终状态

11:02:37 最终核对：

- 注册表仍为 DWORD `CpuPriorityClass=6`，`PerfOptions` 只有这一项；**永久保留，已采用**。没有给 `python.exe`、llama 或其它映像设置 IFEO。
- CapsWriter 主进程 **57716**、两个子进程 **57664 / 50384** 全部 **AboveNormal**，均为项目原路径，亲和性仍为 `0xFFF`；旧 PID 4132 / 3224 / 17652 已结束，没有额外孤儿。
- llama-server 仍为 **54840、AboveNormal**；转写仍为 **45264、AboveNormal**。二者 PID、命令行、优先级、亲和性与本轮开始前逐项相同。三个计划任务的状态、Priority、程序、参数、工作目录都未改变。
- 40 秒负载进程 **46380** 已退出，确认无残留；负载期间采样 CPU 为 100%，退出尾部降至 38%。收尾约 39%，未停止其它项目的真实工作。两服务健康检查正常，识别与润色请求全部成功。
- 安装脚本经 Windows PowerShell 解析及真实注册表片段重复执行验证；完整安装脚本未在 ITX 重跑，避免无必要重新注册任务。`git diff --check` 通过。
- 本轮改动为 `server/install-autostart.ps1`、`server/README.md`、本文。Mac 日志和录音未改；未 commit / push，未运行 `client-mac/build.sh`。原有未跟踪文件 `docs/2026-10-29-handoff.md` 未动。
