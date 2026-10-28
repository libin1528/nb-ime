# 服务端：ITX 上的 CapsWriter

识别跑在局域网里的 ITX（`itx-1.local`，RX 6700 XT 12GB），用的是 [CapsWriter-Offline](https://github.com/HaujetZhao/CapsWriter-Offline) v2.6 的服务端，模型 Qwen3-ASR-1.7B（q5_k）。解码走 Vulkan，AMD 显卡能用上，显存约 1.6GB，进程内存几十 MB。

## 现在的部署

| 项 | 值 |
|---|---|
| 目录 | `C:\Users\qyqx1\CapsWriter-Offline` |
| 模型 | `models\Qwen3-ASR\Qwen3-ASR-1.7B\` |
| 监听 | `127.0.0.1:6016`（只听本机，客户端走 ssh 隧道，防火墙没动） |
| 自启 | 计划任务 `CapsWriterServer`，登录后启动，S4U 后台运行，挂了 1 分钟内重启 |
| 日志 | `logs\server_latest.log`（INFO 级别会记下识别出的文字） |

对 `config_server.py` 的改动只有两处：`addr = '127.0.0.1'`、`enable_tray = False`。

## 从零部署

1. 在 Mac 上下载（ITX 直连 GitHub 只有约 240KB/s）：
   - `CapsWriter-Offline-20260914.zip`（v2.6 release，105MB）
   - `Qwen3-ASR-1.7B-q5_k.zip`（models release，1.9GB）
2. `scp` 到 ITX，解压：服务端解到 `C:\Users\qyqx1\`，模型解到 `CapsWriter-Offline\models\Qwen3-ASR\`。
   Mac 上的 `unzip` 会把包里的中文文件名弄坏，要在 ITX 上用 `Expand-Archive` 解。
3. 改 `config_server.py` 的上面两处。
4. 在 ITX 上跑 `install-autostart.ps1`。

## 常用操作

```powershell
schtasks /end /tn CapsWriterServer; schtasks /run /tn CapsWriterServer   # 重启
Get-Content -Tail 20 -Encoding UTF8 C:\Users\qyqx1\CapsWriter-Offline\logs\server_latest.log
```

## 协议

客户端与服务端之间是 WebSocket 文本帧（子协议 `binary`），格式见 CapsWriter 的 `core/protocol.py`：

- 客户端 → 服务端：`{task_id, source:"mic", data, is_final, time_start, seg_duration, seg_overlap, context, language}`，`data` 是 16kHz 单声道 float32 的 base64；最后一帧 `data` 为空、`is_final` 为 true。
- 服务端 → 客户端：`{task_id, is_final, text, ...}`。
- `context` 是热词提示。人声太弱时 Qwen3-ASR 会把它原样抄出来，客户端有检测与倒序复核（见 `tools/hotword_echo_test.py`）。
- 多个客户端可以同时连，服务端单模型排队，按连接轮转。
