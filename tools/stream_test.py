"""按真实语速把一段录音流式送给服务端，看分段预览多久出一次、准不准，以及松开后完整重认要多久。

用法：python3 stream_test.py <16kHz 单声道 WAV 或 AIFF> [片段秒数 ...]
需要客户端的隧道开着（127.0.0.1:16016）。
"""
import asyncio, base64, json, subprocess, sys, tempfile, time, uuid

import numpy as np
import websockets

URL = "ws://127.0.0.1:16016"
CTX = "ClawChat，ClawNest，Liveware，小圆"
PREVIEW_CTX = CTX


def load(path):
    with tempfile.NamedTemporaryFile(suffix=".wav") as f:
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEF32@16000", "-c", "1", path, f.name], check=True)
        raw = open(f.name, "rb").read()
    i = raw.find(b"data") + 8
    return np.frombuffer(raw[i:i + (len(raw) - i) // 4 * 4], dtype=np.float32)


def msg(tid, data, final, seg, ov, ctx=CTX):
    return json.dumps(dict(task_id=tid, source="mic", data=data, is_final=final, time_start=time.time(),
                           seg_duration=seg, seg_overlap=ov, context=ctx, language="auto"))


async def run(audio, seg, ov):
    preview, full = str(uuid.uuid4()), str(uuid.uuid4())
    t0 = time.time()
    events = []
    # 服务端的音频缓存按连接分，预览和完整识别必须各走一条连接
    async with websockets.connect(URL, subprotocols=["binary"], max_size=None) as wp, \
            websockets.connect(URL, subprotocols=["binary"], max_size=None) as wf:
        async def reader(ws, tid):
            while True:
                m = json.loads(await ws.recv())
                events.append((time.time() - t0, m["task_id"], m["is_final"], m["text"]))
                if m["task_id"] == tid and m["is_final"]:
                    return

        rp, rf = asyncio.create_task(reader(wp, preview)), asyncio.create_task(reader(wf, full))
        step = 1600  # 0.1 秒
        for i in range(0, len(audio), step):
            b64 = base64.b64encode(audio[i:i + step].tobytes()).decode()
            await wp.send(msg(preview, b64, False, seg, ov, PREVIEW_CTX))
            await wf.send(msg(full, b64, False, 60.0, 4.0))
            await asyncio.sleep(0.1)
        released = time.time() - t0
        await wf.send(msg(full, "", True, 60.0, 4.0))
        await wp.send(msg(preview, "", True, seg, ov, PREVIEW_CTX))
        await asyncio.gather(rp, rf)
    print(f"\n== 片段 {seg}s / 重叠 {ov}s，录音 {len(audio)/16000:.1f}s，{released:.1f}s 时松开")
    for t, tid, fin, text in events:
        tag = "完整" if tid == full else ("预览·末" if fin else "预览")
        print(f"  {t:5.1f}s  {tag:5}  {text}")


async def main():
    global PREVIEW_CTX
    audio = load(sys.argv[1])
    for seg in [float(x) for x in sys.argv[2:]] or [2.0, 3.0]:
        for ctx in (CTX, ""):
            PREVIEW_CTX = ctx
            print(f"\n## 预览{'带' if ctx else '不带'}热词", end="")
            await run(audio, seg, 0.5)


asyncio.run(main())
