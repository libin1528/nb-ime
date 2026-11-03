# 2026-11-03 给 ClawChat 的转写接口；在外面用

## 转写接口

ClawChat 要做客户端语音输入，转写走 OpenAI 兼容的 `/audio/transcriptions`（设备直连主人配的服务）。PM 想先拿 ITX 上的两个模型测：润色那个 llama-server 本来就是 OpenAI 兼容，能直接用；识别那个 CapsWriter 是自有 WebSocket 协议，接不上，所以加了 `server/transcribe_api.py` 转一道，部署和用法见 `server/README.md`「给 ClawChat 用的转写接口」。

- 只用标准库：HTTP 用 `ThreadingHTTPServer`，multipart 自己按 boundary 切，WebSocket 客户端自己写了几十行（只收发文本帧，回 ping）。ITX 上装好 Python 就能跑，换机器也不用 pip。
- 掩码几 MB 的帧时逐字节异或太慢，当成大整数一次异或。
- m4a 的 moov 常在文件尾，ffmpeg 从管道读会报「moov atom not found」，先落成临时文件再解。
- 识别参数照 Mac 客户端完整识别那一路：分段 60 秒、重叠 4 秒，每帧送 10 秒音频。74 秒的录音跨两段，结果连得上。
- `language` 从 OpenAI 的 ISO 代码换成 CapsWriter 的小写英文全称（`core/server/engines/language.py`），不认识的一律 auto。
- 只转一道，不做客户端那些「抄热词表」检查，README 里写了要调用方自己防。

实测（经 ssh 隧道，2026-11-03）：2 秒的 m4a（AAC 22.05kHz 单声道）0.3 秒回来，74 秒的 5 秒；坏文件回 400 和 ffmpeg 的报错，缺 `file` 回 400。

## 在外面用

11-02 起 `~/.ssh/config` 会在不在办公室时把 `winrig` 改到公网端口映射，客户端的隧道本来就是 `ssh winrig`，所以在外面本来就能连。在办公室里用 `CLAWCHAT_FORCE_REMOTE=1` 强制走公网那条测过：识别握手 101、润色 `/health`、转写都通。

缺的是换网络时的空窗：旧隧道要等 `ServerAlive` 两次没回（15 秒 × 2）才断，再 3 秒重开，这段时间按住说话没反应。现在 `NetWatch`（`Network.swift`）盯着 `NWPathMonitor` 和睡眠唤醒，网络变了等 2 秒稳定后重开隧道和两条 WebSocket；正在说话、等结果、润色、等焦点时每 2 秒再看一次，最多等 30 秒。网卡、状态、地址族都没变的回调不算变化，启动时的第一次回调也不算。

没测的：真的离开办公室换网络那一下。在办公室里没法不打断正在用的网络去模拟，等下次在外面时看日志里有没有「换了网络，重开隧道」、之后多久「已连上」。

设置页「连接」底下和「润色」页的「录音 / 文字不出局域网」改成「不经过别人的服务器」：走公网时录音确实出了局域网，只是经 ssh 加密直达自己的 ITX。首页三份 README 里「录音不出家门」的说法没动。
