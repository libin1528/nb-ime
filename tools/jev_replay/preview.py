"""Compare live preview-time Jev requests with a request started after Apple finalizes."""

import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
from statistics import median
import subprocess
from time import perf_counter, time

from candidate_lexicon import CandidateLexicon
from evaluate import Polisher, apple_actions, ask_jev, corrected, expand_slots, jev_actions, make_slots, normalized, request_jev, score_arm


MAX_EARLY_REQUESTS = 4
MAX_EARLY_IN_FLIGHT = 2
ARMS = ("serial", "preview")


def signature(text, slots):
    # The current prompt includes the entire raw transcript and assigns option IDs in order.
    return text, tuple((s["start"], s["end"], s["original"], tuple(value for value, _ in s["options"])) for s in slots)


def prepare(capture, context, lexicon):
    slots = make_slots(capture)
    expanded, _ = expand_slots(capture["text"], slots, context, lexicon)
    return expanded, apple_actions(slots)


@dataclass
class Query:
    text: str
    slots: list
    started_wall: float = 0.0
    finished: float = 0.0
    network_ms: float = 0.0
    error: str = ""
    questions: dict = None

    def run(self, key, context):
        self.started_wall = time()
        try:
            if self.questions is None:
                answers, self.network_ms = ask_jev(self.text, self.slots, key, context)
            else:
                answers, self.network_ms = request_jev(None, self.questions, key, context)
            return answers
        except RuntimeError as exc:
            self.error = str(exc)
            raise
        finally:
            self.finished = perf_counter()


class PreviewRequests:
    def __init__(self, executor, pending, key, context, lexicon):
        self.executor = executor
        self.pending = pending
        self.key = key
        self.context = context
        self.lexicon = lexicon
        self.observed = []
        self.requests = {}
        self.released = None
        self.release_time = None

    def observe(self, capture):
        slots, _ = prepare(capture, self.context, self.lexicon)
        tag = signature(capture["text"], slots)
        received = perf_counter()
        self.observed.append((tag, received, self.released is None))
        if self.released is not None or tag in self.requests or not any(s["options"] for s in slots):
            return
        self.pending.difference_update([future for future in self.pending if future.done()])
        if len(self.requests) >= MAX_EARLY_REQUESTS or len(self.pending) >= MAX_EARLY_IN_FLIGHT:
            return
        query = Query(capture["text"], slots)
        future = self.executor.submit(query.run, self.key, self.context)
        self.pending.add(future)
        self.requests[tag] = query, future

    def release(self, wall_time, received):
        self.released = wall_time
        self.release_time = received

    def match(self, tag):
        query, future = self.requests.get(tag, (None, None))
        if query and 0 < query.started_wall < self.released:
            return query, future
        return None, None

    def diagnostics(self, tag):
        held = [value for value, _, before_release in self.observed if before_release]
        same_text = any(value[0] == tag[0] for value in held)
        requests = [query for query, _ in self.requests.values() if 0 < query.started_wall < self.released]
        return {
            "held_previews": len(held),
            "last_held_preview": held[-1][0] if held else None,
            "same_text_while_held": same_text,
            "same_normalized_text_while_held": any(normalized(value[0]) == normalized(tag[0]) for value in held),
            "same_request_while_held": tag in held,
            "same_request_after_release": any(value == tag for value, _, held in self.observed if not held),
            "early_requests": len(requests),
            "snapshots": [{"text": value[0], "slots": len(value[1]), "matches_final": value == tag,
                           "while_held": held, "from_release_ms": (received - self.release_time) * 1000}
                          for value, received, held in self.observed],
        }

    def audit(self):
        return [
            {"preview": query.text,
             "started_from_release_ms": (query.started_wall - self.released) * 1000,
             "finished_from_release_ms": (query.finished - self.release_time) * 1000,
             "network_ms": query.network_ms, "error": query.error}
            for query, _ in self.requests.values()
        ]


def run_pair(row, capture, final_received, preview, serial_executor, polisher, key, context, lexicon):
    raw = capture["text"]
    slots, (flags, changes) = prepare(capture, context, lexicon)
    tag = signature(raw, slots)
    prepared = perf_counter()
    row.update(preview.diagnostics(tag))
    row["final_transcript"] = raw
    if not raw.strip() or capture["finalize_ms"] > 550:
        row["skip"] = "local final unavailable within the 550 ms production budget"
        return

    def resolve(query, answers):
        started = perf_counter()
        marked, proposed = jev_actions(slots, answers, flags, changes)
        staged = corrected(raw, slots, proposed, context)
        wait = max(query.finished, prepared) - final_received
        return marked, staged, 1000 * (wait + perf_counter() - started)

    serial = Query(raw, slots)
    serial_future = serial_executor.submit(serial.run, key, context)
    early, early_future = preview.match(tag)
    row["route"] = "reuse" if early else "final_request"
    if early:
        try:
            answers = early_future.result()
            row["reuse_ready_at_final"] = early.finished <= final_received
        except RuntimeError:
            # If a matching early request failed, start a fresh request now for this arm.
            row["route"] = "retry_final"
            early = Query(raw, slots)
            answers = early.run(key, context)
        preview_result = resolve(early, answers)
    serial_result = resolve(serial, serial_future.result())
    if not early:
        if not row["held_previews"]:
            row["fallback_reason"] = "no_preview_before_release"
        elif not row["same_text_while_held"]:
            row["fallback_reason"] = "transcript_changed"
        elif not row["same_request_while_held"]:
            row["fallback_reason"] = "slots_or_candidates_changed"
        else:
            row["fallback_reason"] = "matching_request_not_started_before_release"
        preview_result = serial_result

    score_pair(row, capture, slots, (serial_result, preview_result), polisher)
    row["serial_jev_ms"] = serial.network_ms


def score_pair(row, capture, slots, results, polisher):
    decisions = dict(zip(ARMS, results))
    polished = {}
    order = ARMS if row["sample"]["id"].endswith(("0", "2", "4", "6", "8")) else ARMS[::-1]
    for arm in order:
        marked, staged, elapsed = decisions[arm]
        if staged not in polished:
            polished[staged] = polisher.run(staged)
        row["arms"][arm] = score_arm(row["sample"], capture, slots, marked, staged, polished[staged], elapsed, bool(slots))


def p95(values):
    return sorted(values)[math.ceil(len(values) * 0.95) - 1]


def summarize(rows):
    paired = [row for row in rows if all(arm in row["arms"] for arm in ARMS)]
    summary = {"paired": len(paired), "failed": sum("error" in r for r in rows),
               "skipped": sum("skip" in r for r in rows), "routes": dict(Counter(row["route"] for row in paired))}
    for field in ("held_previews", "same_text_while_held", "same_normalized_text_while_held", "same_request_while_held",
                  "same_request_after_release", "early_requests", "reuse_ready_at_final"):
        summary[field] = sum(row.get(field, 0) for row in paired)
    summary["fallback_reasons"] = dict(Counter(row["fallback_reason"] for row in paired if "fallback_reason" in row))
    summary["last_held_preview_changed"] = sum(
        row.get("last_held_preview") is not None and row["last_held_preview"] != row["final_transcript"] for row in paired
    )
    summary["sent_during_hold"] = sum(bool(row["early_requests"]) for row in paired)
    summary["early_request_failures"] = sum(bool(q["error"]) for row in rows for q in row["requests"])
    if not paired:
        return summary
    for arm in ARMS:
        items = [row["arms"][arm] for row in paired]
        release = [item["release_ms"] for item in items]
        summary[arm] = {
            "median_ms": round(median(release)), "p95_ms": round(p95(release)),
            "fixed_before_polish": sum(item["candidate_target_improved"] for item in items),
            "damaged_before_polish": sum(item["candidate_target_worsened"] for item in items),
            "fixed_after_polish": sum(item["asr_target_wrong"] and not item["final_target_wrong"] for item in items),
            "damaged_after_polish": sum(not item["asr_target_wrong"] and item["final_target_wrong"] for item in items),
            "worsened_sentences_before_polish": sum(item["candidate_distance"] > item["raw_distance"] for item in items),
        }
    saved = [row["arms"]["serial"]["release_ms"] - row["arms"]["preview"]["release_ms"] for row in paired]
    summary["saved_ms"] = {"median": round(median(saved)), "p95": round(p95(saved)), "max": round(max(saved))}
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--by-segment", action="store_true", help="reuse stable local decisions across transcript revisions")
    options = parser.parse_args()
    root = options.directory.resolve()
    key = os.environ.get("TYPESAFE_API_KEY", "").strip()
    if not key:
        parser.error("provide TYPESAFE_API_KEY")
    samples = json.loads(Path(__file__).with_name("samples.json").read_text())
    context = json.loads(Path(__file__).with_name("context.json").read_text())
    context["hotwords"] = list(dict.fromkeys(context["hotwords"] + [rule["to"] for rule in context["rules"]]))
    lexicon = CandidateLexicon(context["hotwords"])
    scheduler, compare, summarize_run = PreviewRequests, run_pair, summarize
    filename = "preview-results.json"
    if options.by_segment:
        from segment_preview import SegmentLexicon, SegmentRequests, run_segment_pair, summarize_segments

        lexicon = SegmentLexicon(lexicon)
        scheduler, compare, summarize_run = SegmentRequests, run_segment_pair, summarize_segments
        filename = "segment-preview-results.json"
    audio = [str(root / "audio" / f"{sample['id']}.pcm") for sample in samples]
    polisher = Polisher(root / "probe", context)
    runs = []
    pending = set()
    try:
        polisher.run("这是同一批合成语音的润色预热样本。")
        with ThreadPoolExecutor(MAX_EARLY_IN_FLIGHT) as early_executor, ThreadPoolExecutor(2) as serial_executor:
            with subprocess.Popen([str(root / "probe"), "preview", *audio], text=True,
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE) as process:
                for index, sample in enumerate(samples):
                    row = {"sample": sample, "arms": {}}
                    preview = scheduler(early_executor, pending, key, context, lexicon)
                    runs.append((row, preview))
                    begin = json.loads(process.stdout.readline())
                    if begin != {"event": "begin", "id": sample["id"]}:
                        raise RuntimeError(f"unexpected replay start: {begin}")
                    for line in process.stdout:
                        received = perf_counter()
                        event = json.loads(line)
                        if event["event"] == "preview":
                            preview.observe(event)
                        elif event["event"] == "release":
                            preview.release(event["wall_time"], received)
                        elif event["event"] == "final":
                            if event["id"] != sample["id"] or preview.released is None:
                                raise RuntimeError(f"invalid replay final for {sample['id']}")
                            try:
                                compare(row, event["capture"], received, preview, serial_executor, polisher, key, context, lexicon)
                            except RuntimeError as exc:
                                row["error"] = str(exc)
                            break
                    else:
                        raise RuntimeError(f"replay ended before the final for {sample['id']}")
                    print(sample["id"], row.get("error") or row.get("skip") or row["route"],
                          "early requests", row["early_requests"], flush=True)
                    if index + 1 < len(samples):
                        process.stdin.write("next\n")
                        process.stdin.flush()
                if process.wait(timeout=10):
                    raise RuntimeError("Apple preview probe failed")
    finally:
        polisher.close()

    rows = []
    for row, preview in runs:
        row["requests"] = preview.audit()
        rows.append(row)
    summary = summarize_run(rows)
    (root / filename).write_text(json.dumps({"summary": summary, "rows": rows}, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return int(summary["failed"] > 0)


if __name__ == "__main__":
    raise SystemExit(main())
