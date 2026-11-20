"""Replay 16 kHz mono PCM16 WAVs in real time against CapsWriter; emit JSONL traces.

python tools/qwen_preview_trial.py --mode prefix --url ws://127.0.0.1:6016 sample.wav
Modes: prefix (experimental), dual (quality mode's remote streams), speed (segmented), full (final only).
"""
import argparse
from array import array
import base64
import concurrent.futures
from contextlib import ExitStack
import json
from pathlib import Path
import sys
import time
import uuid
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "server"))
from transcribe_api import WS


class Stream:
    def __init__(self, url, words, segment, overlap):
        self.ws = WS(url, 30)
        self.fields = dict(task_id=uuid.uuid4().hex, source="mic", time_start=time.time(),
                           language="auto", context=words, seg_duration=segment, seg_overlap=overlap)

    def send(self, pcm, final=False):
        self.ws.send(json.dumps(dict(self.fields, data=base64.b64encode(pcm).decode(), is_final=final)))

    def receive(self, on_partial=None):
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("task_id") == self.fields["task_id"]:
                if msg["is_final"]:
                    return msg["text"]
                if on_partial:
                    on_partial(msg["text"])


def draft(url, words, pcm):
    stream = Stream(url, words, 60, 4)
    try:
        stream.send(pcm)
        stream.send(b"", True)
        return stream.receive()
    finally:
        stream.ws.close()


def replay(path, mode, url, words):
    with wave.open(str(path), "rb") as wav:
        if (wav.getframerate(), wav.getnchannels(), wav.getsampwidth()) != (16000, 1, 2):
            raise ValueError(f"Expected 16 kHz mono PCM16: {path}")
        pcm = array("f", (v / 32768 for v in array("h", wav.readframes(wav.getnframes())))).tobytes()
    events = []
    draft_seconds = []
    with ExitStack() as stack:
        executor = stack.enter_context(concurrent.futures.ThreadPoolExecutor(max_workers=1))
        full = Stream(url, words, 4, .5) if mode == "speed" else Stream(url, words, 60, 4)
        stack.callback(full.ws.close)
        remote = None
        if mode == "dual":
            remote = Stream(url, words, 2, .5)
            stack.callback(remote.ws.close)
        start = time.monotonic()
        elapsed = lambda: time.monotonic() - start

        def publish(text):
            if text:
                events.append([round(elapsed(), 3), text])

        if remote:
            reader = executor.submit(remote.receive, publish)
        elif mode == "speed":
            reader = executor.submit(full.receive, publish)
        pending = None
        next_draft = 1.2
        for offset in range(0, len(pcm), 6400):
            chunk = pcm[offset:offset + 6400]
            end = offset + len(chunk)
            seconds = end / 64000
            time.sleep(max(0, seconds - elapsed()))
            full.send(chunk)
            if remote:
                remote.send(chunk)
            if pending and pending.done():
                publish(pending.result())
                pending = None
            if mode == "prefix" and not pending and seconds >= next_draft and end < len(pcm):
                pending = executor.submit(draft, url, words, pcm[:end])
                draft_seconds.append(round(seconds, 2))
                next_draft = seconds + max(1.4, seconds * .7)
        released = elapsed()
        full.send(b"", True)
        final = reader.result() if mode == "speed" else full.receive()
        latency = elapsed() - released
        if remote:
            remote.send(b"", True)
            reader.result()
        if pending:
            pending.result()  # surface failures; late drafts never become visible
    return dict(case=path.stem, mode=mode, released=round(released, 3),
                preview=[ev for ev in events if ev[0] < released], final=final,
                release_ms=round(latency * 1000), draft_audio_s=draft_seconds)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("wav", type=Path, nargs="+")
    p.add_argument("--mode", choices=["prefix", "dual", "speed", "full"], action="append")
    p.add_argument("--url", default="ws://127.0.0.1:16016")
    p.add_argument("--context", default="")
    args = p.parse_args()
    modes = args.mode or ["dual", "prefix", "full"]
    for index, wav in enumerate(args.wav):
        for mode in modes[index % len(modes):] + modes[:index % len(modes)]:
            print(json.dumps(replay(wav, mode, args.url, args.context), ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
