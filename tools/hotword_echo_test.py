import asyncio, base64, json, sys, time, uuid, subprocess
import numpy as np, websockets

def load(path):
    raw = open(path, "rb").read()
    # 跳过 WAV 头：找 data 块
    i = raw.find(b"data") + 8
    return np.frombuffer(raw[i:i + (len(raw) - i) // 4 * 4], dtype=np.float32)

async def rec(ws, audio, ctx):
    tid = str(uuid.uuid4())
    base = dict(task_id=tid, source="mic", is_final=False, time_start=time.time(), seg_duration=60.0, seg_overlap=4.0, context=ctx, language="auto")
    await ws.send(json.dumps({**base, "data": base64.b64encode(audio.tobytes()).decode()}))
    await ws.send(json.dumps({**base, "data": "", "is_final": True}))
    while True:
        m = json.loads(await ws.recv())
        if m["task_id"] == tid and m["is_final"]:
            return m["text"]

async def main():
    words = ["ClawChat", "ClawNest", "Liveware", "小圆"]
    ctxs = {
        "现状": "，".join(words),
        "空": "",
        "句子": "本段语音可能提到这些词：" + "、".join(words) + "。",
        "换行": "\n".join(words),
    }
    async with websockets.connect("ws://127.0.0.1:16016", subprotocols=["binary"], max_size=None) as ws:
        for f in sys.argv[1:]:
            if f.startswith("noise:"):
                a = np.zeros(int(16000 * float(f[6:])), dtype=np.float32)
            else:
                a = load(f)
                a = np.concatenate([np.zeros(16000, np.float32), a, np.zeros(8000, np.float32)])
            a = a + np.random.default_rng(0).normal(0, 0.003, len(a)).astype(np.float32)
            row = [f.split("/")[-1], f"{len(a)/16000:.1f}s"]
            for name, c in ctxs.items():
                row.append(f"{name}={await rec(ws, a, c)!r}")
            print(" | ".join(row), flush=True)

asyncio.run(main())
