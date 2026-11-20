"""Score the same synthetic utterances through the current speed path, Apple metadata, and Jev."""
import argparse
from collections import defaultdict
from difflib import SequenceMatcher
from itertools import product
import json
import math
import os
from pathlib import Path
import re
from statistics import median
import subprocess
from time import perf_counter
import unicodedata
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

MODEL = "jev-1.14.0"
APPLE_LOW = 0.80
APPLE_MARGIN = 0.15
JEV_SUSPECT = 0.75
JEV_CHOICE = 0.75
JEV_CONFIDENCE = 0.55
PROMPT_ARMS = ("jev", "jev_whole", "jev_blank")
EXPANDED_ARM = "jev_expanded"


def normalized(text):
    return "".join(c for c in unicodedata.normalize("NFKC", text).casefold() if c.isalnum())


def tokens(text):
    return [(normalized(m[0]), m.start(), m.end()) for m in re.finditer(r"[a-zA-Z0-9]+|[^\W_]", text)]


def edits(original, alternative):
    left, right = tokens(original), tokens(alternative)
    match = SequenceMatcher(None, [x[0] for x in left], [x[0] for x in right], autojunk=False)
    for kind, a, b, c, d in match.get_opcodes():
        if kind != "replace":
            continue
        start, end = left[a][1], left[b - 1][2]
        alt_start, alt_end = right[c][1], right[d - 1][2]
        if end - start <= 18 and alt_end - alt_start <= 18:
            yield start, end, alt_start, alt_end


def confidence_runs(candidate):
    start = 0
    for run in candidate["runs"]:
        end = start + len(run["text"])
        score = run.get("confidence")
        if score is not None and 0 <= score <= 1 and normalized(run["text"]):
            yield start, end, score
        start = end


def confidence_at(candidate, start, end):
    values = [score for a, b, score in confidence_runs(candidate) if a < end and start < b]
    return min(values, default=None)


def overlapping(a, b):
    return a[0] < b[1] and b[0] < a[1]


def make_slots(capture):
    slots = []
    offset = 0
    for segment in capture["segments"]:
        candidate = segment["primary"]
        text = candidate["text"]
        replacements = defaultdict(dict)
        for alternative in segment["alternatives"]:
            for a, b, c, d in edits(text, alternative["text"]):
                value = alternative["text"][c:d]
                score = confidence_at(alternative, c, d)
                previous = replacements[a, b].get(value)
                if previous is None or score is not None and score > previous:
                    replacements[a, b][value] = score
        ranges = [(a, b) for a, b, score in confidence_runs(candidate)
                  if score < APPLE_LOW and b - a <= 18
                  and not any(overlapping((a, b), span) for span in replacements)]
        for a, b in sorted(set(ranges) | replacements.keys()):
            slots.append({"start": offset + a, "end": offset + b, "original": text[a:b],
                          "confidence": confidence_at(candidate, a, b),
                          "options": list(replacements[a, b].items())[:5]})
        offset += len(text)
    return slots


def apple_actions(slots):
    flags, changes = set(), {}
    for index, slot in enumerate(slots):
        score = slot["confidence"]
        if score is None or score >= APPLE_LOW:
            continue
        flags.add(index)
        better = [(value, alt_score) for value, alt_score in slot["options"]
                  if alt_score is not None and alt_score >= score + APPLE_MARGIN]
        if better:
            changes[index] = max(better, key=lambda item: item[1])
    return flags, changes


def replace_slot(text, slot, value):
    return text[:slot["start"]] + value + text[slot["end"]:]


def jev_questions(text, slots, prompt="jev", nearby_only=False):
    questions = {}
    scope = "结合给出的相邻上下文。" if nearby_only else "结合相邻词和整句。"
    for index, slot in enumerate(slots):
        marked = replace_slot(text, slot, "【" + slot["original"] + "】")
        instructions = (f"中文语音输入转写片段：{marked}。判断方括号内的内容是否像语音识别错误。"
                        f"{scope}热词和固定替换仅在贴合上下文时提供线索，"
                        "保留已正确出现的热词。口语、名字、中英混说本身都很正常。")
        questions[f"flag{index}"] = {
            "type": "noul", "instructions": instructions,
            "criteria": {"true": "这里明显存在听写错误，值得提醒用户复核。",
                         "false": "这段说法合理，或目前缺乏足够证据。"},
        }
        if slot["options"]:
            options = {f"alt{i}": value for i, (value, _) in enumerate(slot["options"])}
            options["keep"] = slot["original"]
            pick_instructions = f"{instructions} 只有明显更符合说话者原意的识别候选才选为替换。"
            if prompt == "jev_whole":
                options = {name: replace_slot(text, slot, value) for name, value in options.items()}
                pick_instructions = "这些都是同一段中文语音的整句转写，只在一个片段上有差别。请选择最符合说话者原意的整句。"
            elif prompt == "jev_blank":
                blanked = replace_slot(text, slot, "____")
                pick_instructions = f"中文语音转写：{blanked}。哪个候选填入空格最符合说话者原意？"
            if prompt != "jev":
                pick_instructions += ("热词和固定替换仅在贴合上下文时提供线索。口语、名字、中英混说本身都很正常。"
                                      "只有证据明显支持改动时才选替换。")
            options["unsure"] = "候选证据不足，保留原词"
            questions[f"pick{index}"] = {
                "type": "choice", "criteria": options,
                "instructions": pick_instructions + "原字词合理选 keep，几个读法都合理或缺乏证据选 unsure。",
            }
    return questions


def ask_jev(text, slots, key, context, prompt="jev"):
    questions = jev_questions(text, slots, prompt)
    # Each question sees the shared state. Keep the original transcript out of
    # that state for the two variants so it cannot reveal the word in the blank.
    return request_jev(text if prompt == "jev" else None, questions, key, context)


def request_jev(text, questions, key, context):
    if not questions:
        return {}, 0.0
    state = {"转写": text} if text is not None else {}
    state.update(热词=context["hotwords"], 固定替换=context["rules"])
    payload = {"model": MODEL, "state": state, "questions": questions}
    request = Request("https://api.typesafe.ai/v1/systemone",
                      data=json.dumps(payload, ensure_ascii=False).encode(),
                      headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    started = perf_counter()
    try:
        with urlopen(request, timeout=5) as response:
            body = json.load(response)
    except HTTPError as exc:
        fields = ""
        if exc.code == 422:
            detail = json.load(exc).get("detail")
            if isinstance(detail, list):
                fields = " " + ", ".join(
                    ".".join(map(str, entry.get("loc", []))) + ":" + entry.get("type", "")
                    for entry in detail[:3]
                )
        raise RuntimeError(f"Jev returned HTTP {exc.code}{fields}") from None
    except (URLError, TimeoutError) as exc:
        raise RuntimeError(f"Jev connection failed ({type(exc).__name__})") from None
    return body["answers"], (perf_counter() - started) * 1000


def segment_jev(text, key, context):
    atoms = tokens(text)
    if not atoms:
        return [], 0.0
    questions = {}
    for index in range(1, len(atoms)):
        _, _, left_end = atoms[index - 1]
        _, right_start, _ = atoms[index]
        # Whitespace in ASR text is allowed within a mixed-script term. Punctuation is a hard boundary.
        if text[left_end:right_start].strip():
            continue
        marked = text[:right_start] + "｜" + text[right_start:]
        questions[f"boundary{index}"] = {
            "type": "noul",
            "instructions": (f"整句转写是「{marked}」。标记｜的地方应该断成两个词吗？"
                             "结合左右词、整句、已知热词和固定替换。"),
            "criteria": {"true": "标记两侧是不同词。按整句语义切分。",
                         "false": "标记两侧属于同一个词、姓名或固定术语。"},
        }
    answers, ms = request_jev(text, questions, key, context)
    spans = []
    start = atoms[0][1]
    for index in range(1, len(atoms)):
        _, _, previous_end = atoms[index - 1]
        _, next_start, _ = atoms[index]
        score = answers.get(f"boundary{index}", {}).get("noul", 1)
        if score >= 0.5 or next_start - start >= 18:
            spans.append((start, previous_end))
            start = next_start
    spans.append((start, atoms[-1][2]))
    return spans, ms


def include_words(text, slots, spans):
    existing = {(slot["start"], slot["end"]) for slot in slots}
    return slots + [
        {"start": start, "end": end, "original": text[start:end], "confidence": None, "options": []}
        for start, end in spans if (start, end) not in existing
    ]


def jev_actions(slots, answers, flags, changes, review_flags=False):
    flags, changes = flags.copy(), changes.copy()
    for index, slot in enumerate(slots):
        suspect = answers.get(f"flag{index}", {}).get("noul")
        if suspect is not None and suspect >= JEV_SUSPECT:
            flags.add(index)
        elif review_flags and suspect is not None and suspect < 0.25:
            flags.discard(index)
        answer = answers.get(f"pick{index}", {})
        choice = answer.get("choice", "")
        probability = answer.get("probabilities", {}).get(choice, 0)
        if probability < JEV_CHOICE or (answer.get("confidence") or 0) < JEV_CONFIDENCE:
            continue
        if choice == "keep":
            changes.pop(index, None)
        elif re.fullmatch(r"alt\d+", choice):
            option = int(choice[3:])
            if option < len(slot["options"]):
                flags.add(index)
                changes[index] = (slot["options"][option][0], probability)
    return flags, changes


def protected_spans(text, context):
    phrases = context["hotwords"] + [rule["from"] for rule in context["rules"]]
    for phrase in phrases:
        prefix = r"(?<![a-zA-Z0-9])" if re.match(r"[a-zA-Z0-9]", phrase) else ""
        suffix = r"(?![a-zA-Z0-9])" if re.search(r"[a-zA-Z0-9]$", phrase) else ""
        yield from (match.span() for match in re.finditer(prefix + re.escape(phrase) + suffix, text, re.I))


def expand_slots(text, slots, context, lexicon):
    expanded = [{**slot, "options": slot["options"].copy()} for slot in slots]
    by_span = {(slot["start"], slot["end"]): slot for slot in expanded}
    protected = list(protected_spans(text, context))
    added = []
    for start, end, word, source in lexicon.proposals(text, slots):
        if any(overlapping((start, end), span) for span in protected):
            continue
        original = text[start:end]
        if normalized(word) == normalized(original):
            continue
        slot = by_span.get((start, end))
        if slot is None:
            slot = {"start": start, "end": end, "original": original, "confidence": None, "options": []}
            by_span[start, end] = slot
            expanded.append(slot)
        if any(normalized(word) == normalized(value) for value, _ in slot["options"]):
            continue
        slot["options"].append((word, None))
        added.append({"start": start, "end": end, "original": original, "candidate": word, "source": source})
    return expanded, added


def corrected(text, slots, changes, context):
    selected = []
    protected = list(protected_spans(text, context))
    for index, (value, score) in sorted(changes.items(), key=lambda item: -item[1][1]):
        slot = slots[index]
        span = (slot["start"], slot["end"])
        if not any(overlapping(span, taken) for taken in protected):
            selected.append((*span, value))
            protected.append(span)
    for start, end, value in sorted(selected, reverse=True):
        text = text[:start] + value + text[end:]
    return text


class Polisher:
    def __init__(self, probe, context):
        self.context = context
        self.process = subprocess.Popen([str(probe), "polish"], text=True,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    def run(self, text):
        item = {"text": text, **self.context}
        self.process.stdin.write(json.dumps(item, ensure_ascii=False) + "\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError("production polish probe exited")
        return json.loads(line)

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=10)
        self.process.stdout.close()


def error_positions(reference, actual):
    return [(a, b) for kind, _, _, a, b in
            SequenceMatcher(None, reference, actual, autojunk=False).get_opcodes() if kind != "equal"]


def target_error_spans(sample, text):
    reference = normalized(sample["ref"])
    target = normalized(sample["target"])
    lo = reference.index(target)
    hi = lo + len(target)
    return [(c, d) for kind, a, b, c, d in
            SequenceMatcher(None, reference, normalized(text), autojunk=False).get_opcodes()
            if kind != "equal" and (a < hi and lo < b or a == b and lo < a < hi)]


def candidate_coverage(sample, capture, slots, context, expanded_slots=None):
    text = capture["text"]
    errors = target_error_spans(sample, text)
    if not errors:
        coverage = {"primary_correct": True, "in_apple_candidates": None, "in_eligible_slots": None}
        if expanded_slots is not None:
            coverage["in_expanded_slots"] = None
        return coverage

    def touches_target_error(start, end):
        span = (len(normalized(text[:start])), len(normalized(text[:end])))
        return any(overlapping(span, (lo, hi)) if lo != hi else span[0] <= lo <= span[1]
                   for lo, hi in errors)

    segment_choices = []
    offset = 0
    for segment in capture["segments"]:
        primary = segment["primary"]["text"]
        choices = [primary]
        if touches_target_error(offset, offset + len(primary)):
            choices += [candidate["text"] for candidate in segment["alternatives"]]
        segment_choices.append(dict.fromkeys(choices))
        offset += len(primary)
    in_apple_candidates = any(not target_error_spans(sample, "".join(choice))
                              for choice in product(*segment_choices))

    protected = list(protected_spans(text, context))

    def reachable(options):
        slot_choices = []
        for index, slot in enumerate(options):
            span = (slot["start"], slot["end"])
            if (slot["options"] and touches_target_error(*span)
                    and not any(overlapping(span, keep) for keep in protected)):
                slot_choices.append([None] + [(index, (value, 1)) for value, _ in slot["options"]])
        return any(
            not target_error_spans(sample, corrected(text, options, dict(change for change in choices if change), context))
            for choices in product(*slot_choices)
        )

    coverage = {"primary_correct": False, "in_apple_candidates": in_apple_candidates,
                "in_eligible_slots": reachable(slots)}
    if expanded_slots is not None:
        coverage["in_expanded_slots"] = coverage["in_eligible_slots"] or reachable(expanded_slots)
    return coverage


def mark_accuracy(sample, text, marks):
    errors = error_positions(normalized(sample["ref"]), normalized(text))
    target = target_error_spans(sample, text)
    spans = [(len(normalized(text[:s["start"]])), len(normalized(text[:s["end"]]))) for s in marks]
    return {
        "hits": sum(any(overlapping(span, error) for error in errors) for span in spans),
        "hit_error_spans": sum(any(overlapping(span, error) for span in spans) for error in errors),
        "false_marks": sum(not any(overlapping(span, error) for error in errors) for span in spans),
        "target_flagged": any(overlapping(span, error) for span in spans for error in target),
    }


def edit_distance(left, right):
    row = list(range(len(right) + 1))
    for i, a in enumerate(left, 1):
        next_row = [i]
        for j, b in enumerate(right, 1):
            next_row.append(min(row[j] + 1, next_row[-1] + 1, row[j - 1] + (a != b)))
        row = next_row
    return row[-1]


def score_arm(sample, capture, slots, marked, staged, output, decision_ms, called):
    raw = capture["text"]
    reference = normalized(sample["ref"])
    marks = [slots[i] for i in sorted(marked)]
    asr_wrong = bool(target_error_spans(sample, raw))
    staged_wrong = bool(target_error_spans(sample, staged))
    return {
        "raw": raw, "staged": staged, "final": output["text"], "marks": marks,
        "prepared": output["prepared"], "replace_hits": output["replace_hits"],
        "polish_note": output["note"], "asr_ms": capture["release_ms"],
        "decision_ms": decision_ms, "polish_ms": output["ms"], "jev_called": called,
        "release_ms": capture["release_ms"] + decision_ms + output["ms"],
        "asr_target_wrong": asr_wrong,
        "final_target_wrong": bool(target_error_spans(sample, output["text"])),
        "candidate_edited": normalized(staged) != normalized(raw),
        "candidate_target_improved": asr_wrong and not staged_wrong,
        "candidate_target_worsened": not asr_wrong and staged_wrong,
        "raw_distance": edit_distance(reference, normalized(raw)),
        "candidate_distance": edit_distance(reference, normalized(staged)),
        "final_distance": edit_distance(reference, normalized(output["text"])),
        **mark_accuracy(sample, raw, marks),
    }


def summarize(rows):
    summary = {}
    for arm in ("current", "apple", *PROMPT_ARMS, "jev_words", EXPANDED_ARM):
        samples = [row["arms"] for row in rows if arm in row["arms"]]
        items = [sample[arm] for sample in samples]
        times = sorted(r["release_ms"] for r in items)
        if not items:
            continue
        summary[arm] = {
            "samples": len(items),
            "asr_target_wrong": sum(r["asr_target_wrong"] for r in items),
            "flagged_target_sentences": sum(r["target_flagged"] for r in items),
            "hit_marks": sum(r["hits"] for r in items),
            "distinct_error_spans": sum(r["hit_error_spans"] for r in items),
            "false_marks": sum(r["false_marks"] for r in items),
            "final_target_correct": sum(not r["final_target_wrong"] for r in items),
            "fixed_target": sum(r["asr_target_wrong"] and not r["final_target_wrong"] for r in items),
            "damaged_target": sum(not r["asr_target_wrong"] and r["final_target_wrong"] for r in items),
            "candidate_edits": sum(r["candidate_edited"] for r in items),
            "candidate_edits_improved": sum(r["candidate_edited"] and r["candidate_target_improved"] for r in items),
            "candidate_edits_worsened": sum(r["candidate_edited"] and r["candidate_target_worsened"] for r in items),
            "raw_edit_distance": sum(r["raw_distance"] for r in items),
            "candidate_edit_distance": sum(r["candidate_distance"] for r in items),
            "final_edit_distance": sum(r["final_distance"] for r in items),
            "candidate_improved_sentence": sum(r["candidate_distance"] < r["raw_distance"] for r in items),
            "candidate_worsened_sentence": sum(r["candidate_distance"] > r["raw_distance"] for r in items),
            "fixed_rule_hits": sum(len(r["replace_hits"]) for r in items),
            "median_ms": round(median(times)),
            "p95_ms": round(times[math.ceil(len(times) * 0.95) - 1]),
            "median_paired_delta_vs_apple_ms": round(median(
                sample[arm]["release_ms"] - sample["apple"]["release_ms"] for sample in samples
            )),
        }
    return summary


def summarize_coverage(rows):
    scored = [row for row in rows if "coverage" in row]
    wrong = [row for row in scored if not row["coverage"]["primary_correct"]]
    summary = {
        "samples": len(scored),
        "primary_correct": len(scored) - len(wrong),
        "primary_wrong": len(wrong),
        "in_apple_candidates": [row["sample"]["id"] for row in wrong if row["coverage"]["in_apple_candidates"]],
        "in_eligible_slots": [row["sample"]["id"] for row in wrong if row["coverage"]["in_eligible_slots"]],
    }
    if any("in_expanded_slots" in row["coverage"] for row in scored):
        summary["in_expanded_slots"] = [row["sample"]["id"] for row in wrong if row["coverage"]["in_expanded_slots"]]
    return summary


def summarize_comparison(rows, arms):
    paired = [row for row in rows if all(arm in row["arms"] for arm in arms)]
    summary = summarize(paired)
    comparison = {}
    for arm in arms:
        if arm not in summary:
            continue
        comparison[arm] = summary[arm]
        for baseline in ("apple", "jev"):
            deltas = sorted(row["arms"][arm]["release_ms"] - row["arms"][baseline]["release_ms"] for row in paired)
            comparison[arm][f"extra_vs_{baseline}_ms"] = {
                "median": round(median(deltas)), "p95": round(deltas[math.ceil(len(deltas) * 0.95) - 1]),
            }
    return comparison


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--without-jev", action="store_true")
    parser.add_argument("--with-segmentation", action="store_true")
    parser.add_argument("--compare-prompts", action="store_true", help="compare current, whole-sentence and blanked choices")
    parser.add_argument("--with-candidate-expansion", action="store_true", help="add hotwords and Mandarin homophones")
    options = parser.parse_args()
    root = options.directory.resolve()
    key = os.environ.get("TYPESAFE_API_KEY", "").strip()
    if not key and not options.without_jev:
        parser.error("provide TYPESAFE_API_KEY or use --without-jev")
    samples = json.loads(Path(__file__).with_name("samples.json").read_text())
    context = json.loads(Path(__file__).with_name("context.json").read_text())
    context["hotwords"] = list(dict.fromkeys(context["hotwords"] + [rule["to"] for rule in context["rules"]]))
    lexicon = None
    if options.with_candidate_expansion:
        try:
            from candidate_lexicon import CandidateLexicon
        except ModuleNotFoundError as exc:
            parser.error(f"{exc}. Install the candidate lexicon dependencies from the experiment README.")
        lexicon = CandidateLexicon(context["hotwords"])
    captures = {}
    for line in (root / "capture.jsonl").read_text().splitlines():
        capture = json.loads(line)
        captures[capture["id"], capture["enriched"]] = capture

    polisher = Polisher(root / "probe", context)
    rows = []
    jev_failures = []
    try:
        polisher.run("这是同一批合成语音的润色预热样本。")
        for index, sample in enumerate(samples):
            baseline = captures.get((sample["id"], False))
            enriched = captures.get((sample["id"], True))
            row = {"sample": sample, "arms": {}}
            rows.append(row)
            if not baseline or not enriched or any(not c["text"].strip() or c["finalize_ms"] > 550
                                                    for c in (baseline, enriched)):
                row["skip"] = "local final unavailable within the 550 ms production budget"
                continue
            started = perf_counter()
            slots = make_slots(enriched)
            flags, changes = apple_actions(slots)
            local_ms = (perf_counter() - started) * 1000
            arms = [("current", baseline, slots, set(), {}, 0.0, False),
                    ("apple", enriched, slots, flags, changes, local_ms, False)]
            expanded_slots = None
            expansion_ms = 0.0
            if lexicon is not None:
                started = perf_counter()
                expanded_slots, added = expand_slots(enriched["text"], slots, context, lexicon)
                expansion_ms = (perf_counter() - started) * 1000
                row["added_candidates"] = added
                row["expansion_ms"] = expansion_ms
            if not options.without_jev:
                order = PROMPT_ARMS if options.compare_prompts else ("jev",)
                if expanded_slots is not None:
                    order += (EXPANDED_ARM,)
                rotation = index % len(order)
                for arm in order[rotation:] + order[:rotation]:
                    try:
                        arm_slots = expanded_slots if arm == EXPANDED_ARM else slots
                        started = perf_counter()
                        prompt = "jev" if arm == EXPANDED_ARM else arm
                        answers, network_ms = ask_jev(enriched["text"], arm_slots, key, context, prompt)
                        jev_flags, jev_changes = jev_actions(arm_slots, answers, flags, changes)
                        decision_ms = local_ms + (perf_counter() - started) * 1000
                        if arm == EXPANDED_ARM:
                            decision_ms += expansion_ms
                        arms.append((arm, enriched, arm_slots, jev_flags, jev_changes, decision_ms, bool(arm_slots)))
                        row[f"{arm}_ms"] = network_ms
                        row[f"{arm}_answers"] = answers
                    except RuntimeError as exc:
                        row[f"{arm}_error"] = str(exc)
                        jev_failures.append(f"{sample['id']} {arm}: {exc}")
            if options.with_segmentation and not options.without_jev:
                try:
                    text = enriched["text"]
                    spans, segmentation_ms = segment_jev(text, key, context)
                    all_slots = include_words(text, slots, spans)
                    answers, contextual_ms = ask_jev(text, all_slots, key, context)
                    started = perf_counter()
                    word_flags, word_changes = jev_actions(all_slots, answers, flags, changes)
                    decision_ms = local_ms + segmentation_ms + contextual_ms + (perf_counter() - started) * 1000
                    arms.append(("jev_words", enriched, all_slots, word_flags, word_changes, decision_ms, bool(all_slots)))
                    row["segmentation"] = [text[a:b] for a, b in spans]
                    row["segmentation_ms"] = segmentation_ms
                    row["contextual_ms"] = contextual_ms
                    narrowed, _ = jev_actions(all_slots, answers, flags, changes, review_flags=True)
                    row["strict_marking"] = mark_accuracy(sample, text, [all_slots[i] for i in sorted(narrowed)])
                except RuntimeError as exc:
                    row["segmentation_error"] = str(exc)
                    jev_failures.append(str(exc))

            row["slots"] = slots
            row["coverage"] = candidate_coverage(sample, enriched, slots, context, expanded_slots)
            polished = {}
            for n in range(len(arms)):
                arm, capture, arm_slots, marked, proposed, decision_ms, called = arms[(index + n) % len(arms)]
                raw = capture["text"]
                staged = corrected(raw, arm_slots, proposed, context)
                if staged not in polished:
                    polished[staged] = polisher.run(staged)
                row["arms"][arm] = score_arm(sample, capture, arm_slots, marked, staged, polished[staged],
                                             decision_ms, called)
            errors = [f"{arm}: {row[f'{arm}_error']}" for arm in (*PROMPT_ARMS, EXPANDED_ARM) if f"{arm}_error" in row]
            print(sample["id"], " ".join(row["arms"]), *errors, flush=True)
    finally:
        polisher.close()
    result = {"context": context, "rows": rows, "summary": summarize(rows),
              "coverage": summarize_coverage(rows), "jev_failures": jev_failures}
    if options.compare_prompts:
        result["prompt_comparison"] = summarize_comparison(rows, PROMPT_ARMS)
    if options.with_candidate_expansion:
        result["candidate_comparison"] = summarize_comparison(rows, ("jev", EXPANDED_ARM))
    (root / "results.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key not in ("context", "rows")},
                     ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
