"""Compare Jev judgments on synthetic name-candidate cases outside the input path."""

import argparse
import json
import os
from pathlib import Path
import sys
from time import perf_counter
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture", type=Path, help="JSON cases marked synthetic")
    args = parser.parse_args()
    cases = json.loads(args.fixture.read_text())
    if not isinstance(cases, list) or not 1 <= len(cases) <= 12:
        parser.error("expected 1–12 synthetic cases")
    if any(not isinstance(case, dict) or case.get("synthetic") is not True
           or any(not isinstance(case.get(k), str) or not 1 <= len(case[k]) <= 240
                  for k in ("id", "text", "original", "name"))
           or case["original"] not in case["text"] for case in cases):
        parser.error("each case needs a short synthetic text and a known candidate")
    key = os.environ.get("TYPESAFE_API_KEY")
    if not key:
        parser.error("TYPESAFE_API_KEY is required for the separate shadow run")

    questions = {}
    for index, case in enumerate(cases):
        marked = case["text"].replace(case["original"], "【" + case["original"] + "】", 1)
        questions[f"pick{index}"] = {
            "type": "choice",
            "instructions": f"语音转写：{marked}。结合上下文判断标记处。表达合理时选 keep，仅在明确是专名时选 name，证据不足选 unsure。",
            "criteria": {"keep": case["original"], "name": case["name"], "unsure": "证据不足"},
        }
    payload = {"model": "jev-1.14.0", "state": {}, "questions": questions}
    request = Request(
        "https://api.typesafe.ai/v1/systemone",
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    started = perf_counter()
    try:
        with urlopen(request, timeout=5) as response:
            answers = json.load(response)["answers"]
    except HTTPError as error:
        sys.exit(f"Jev returned HTTP {error.code}")
    except (URLError, TimeoutError):
        sys.exit("Jev request failed or timed out")
    rows = [{"id": case["id"], "answer": answers.get(f"pick{i}")} for i, case in enumerate(cases)]
    print(json.dumps({"jev_ms": round((perf_counter() - started) * 1000), "cases": rows}, ensure_ascii=False))


if __name__ == "__main__":
    main()
