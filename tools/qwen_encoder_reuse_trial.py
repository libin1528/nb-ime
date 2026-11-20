"""Compare cached and uncached Qwen3-ASR encoder outputs for successive WAV prefixes.

Run in the CapsWriter test environment with its NumPy and ONNX Runtime versions.
python qwen_encoder_reuse_trial.py --capswriter ~/CapsWriter-Offline sample.wav
"""
import argparse
import importlib.util
import json
from pathlib import Path
import time
import wave

import numpy as np


class WindowCache:
    """Keep frontend outputs only for identical ONNX inputs within this utterance."""

    def __init__(self, session):
        self.session = session
        self.outputs = {}
        self.hits = 0
        self.calls = 0

    def run(self, names, inputs):
        self.calls += 1
        key = inputs["chunk_mel"].tobytes()
        if key in self.outputs:
            self.hits += 1
        else:
            self.outputs[key] = self.session.run(names, inputs)
        return self.outputs[key]


def compare(encoder, path, reverse):
    with wave.open(str(path), "rb") as wav:
        if (wav.getframerate(), wav.getnchannels(), wav.getsampwidth()) != (16000, 1, 2):
            raise ValueError(f"Expected mono 16 kHz PCM16: {path}")
        audio = np.frombuffer(wav.readframes(wav.getnframes()), dtype="<i2").astype("float32") / 32768
    ends = []
    deadline = 1.2
    for offset in range(1600, len(audio), 1600):
        secs = offset / 16000
        if secs >= deadline:
            ends.append(offset)
            deadline = secs + max(1.4, secs * .7)
    ends.append(len(audio))
    original = encoder.sess_fe
    cache = WindowCache(original)
    times = {False: [], True: []}
    try:
        for i, end in enumerate(ends):
            outputs = []
            for cached in ([True, False] if (reverse + i) % 2 else [False, True]):
                encoder.sess_fe = cache if cached else original
                t0 = time.perf_counter()
                embedding, _ = encoder.encode(audio[:end])
                times[cached].append(round((time.perf_counter() - t0) * 1000, 2))
                outputs.append(embedding)
            if not np.array_equal(*outputs):
                raise ValueError(f"Encoder changed at {path.name} sample {end}")
    finally:
        encoder.sess_fe = original
    return dict(case=path.stem, prefixes=len(ends), hits=cache.hits, calls=cache.calls,
                cached_ms=times[True], original_ms=times[False])


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--capswriter", type=Path, required=True)
    p.add_argument("wav", type=Path, nargs="+")
    a = p.parse_args()
    engine = a.capswriter / "core/server/engines/qwen_asr_gguf/inference/encoder.py"
    spec = importlib.util.spec_from_file_location("encoder", engine)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    models = a.capswriter / "models/Qwen3-ASR/Qwen3-ASR-1.7B"
    encoder = mod.QwenAudioEncoder(str(models / "qwen3_asr_encoder_frontend.onnx"),
                                   str(models / "qwen3_asr_encoder_backend.onnx"), verbose=False)
    for i, path in enumerate(a.wav):
        print(json.dumps(compare(encoder, path, i)), flush=True)


if __name__ == "__main__":
    main()
