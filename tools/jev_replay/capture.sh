#!/bin/bash
# Run from the repository root on a locked macOS test machine.
set -euo pipefail
experiment=tools/jev_replay
sources=client-mac/Sources
out="${1:?pass an output directory}"
mkdir -p "$out/audio"
swiftc -O "$experiment/Probe.swift" "$sources"/{Polish,DeterminerRestart,SentenceRestart,Spelling,Hotfix,Signfix,HotwordEcho,Replace}.swift -o "$out/probe"
if [[ "${2:-}" == "--compile-only" ]]; then
    exit 0
fi
python3 - "$experiment/samples.json" "$out" <<'PY'
import json
from pathlib import Path
import subprocess
import sys

samples = json.loads(Path(sys.argv[1]).read_text())
out = Path(sys.argv[2])
paths = []
for index, sample in enumerate(samples):
    aiff = out / "audio" / (sample["id"] + ".aiff")
    pcm = aiff.with_suffix(".pcm")
    if not pcm.exists():
        rate = (178, 211, 158)[index % 3]
        subprocess.run(["say", "-v", "Tingting", "-r", str(rate), "-o", str(aiff), sample["ref"]], check=True)
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(aiff), "-ar", "16000",
                        "-ac", "1", "-f", "s16le", str(pcm)], check=True)
        aiff.unlink()
    paths.append(str(pcm))
with (out / "capture.jsonl").open("w") as capture:
    subprocess.run([str(out / "probe"), "capture", *paths], stdout=capture, timeout=360, check=True)
PY
