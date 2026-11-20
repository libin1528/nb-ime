"""Reuse Jev answers scoped to the same word, nearby context, and candidates."""

from collections import Counter
from dataclasses import dataclass
from hashlib import sha256
import json
from time import perf_counter

import jieba

from candidate_lexicon import HAN, LATIN_WORD
from evaluate import apple_actions, corrected, expand_slots, jev_actions, jev_questions, make_slots, tokens
from preview import MAX_EARLY_IN_FLIGHT, MAX_EARLY_REQUESTS, PreviewRequests, Query, score_pair, summarize


CONTEXT_TOKENS = 3


@dataclass(frozen=True)
class Fragment:
    left: str
    original: str
    right: str
    options: tuple

    def questions(self):
        window = self.left + self.original + self.right
        slot = {"start": len(self.left), "end": len(self.left) + len(self.original),
                "original": self.original, "options": [(value, None) for value in self.options]}
        payload = jev_questions(window, [slot], nearby_only=True)
        digest = sha256(json.dumps(payload, ensure_ascii=False, sort_keys=True).encode()).hexdigest()[:20]
        return {kind[:-1] + digest: question for kind, question in payload.items()}


def fragment_for(text, slot):
    start, end = slot["start"], slot["end"]
    left_tokens, right_tokens = tokens(text[:start]), tokens(text[end:])
    left_start = left_tokens[-CONTEXT_TOKENS][1] if len(left_tokens) >= CONTEXT_TOKENS else 0
    right_end = end + right_tokens[CONTEXT_TOKENS - 1][2] if len(right_tokens) >= CONTEXT_TOKENS else len(text)
    fragment = Fragment(text[left_start:start], slot["original"], text[end:right_end],
                        tuple(value for value, _ in slot["options"]))
    return fragment, len(right_tokens) >= CONTEXT_TOKENS


def questions_for(fragments):
    return {name: question for fragment in fragments for name, question in fragment.questions().items()}


class SegmentLexicon:
    def __init__(self, lexicon):
        self.lexicon = lexicon
        self.tokenizer = jieba.Tokenizer()
        self.tokenizer.initialize()

    def prepare(self, capture, context):
        text = capture["text"]
        apple = make_slots(capture)
        known_spans = {(slot["start"], slot["end"]) for slot in apple}
        possible = [(start, end) for word, start, end in self.tokenizer.tokenize(text, HMM=False)
                    if 2 <= len(word) <= 4 and HAN.fullmatch(word)]
        possible.extend(match.span() for match in LATIN_WORD.finditer(text))
        local = [{"start": start, "end": end, "original": text[start:end], "confidence": None, "options": []}
                 for start, end in sorted(set(possible) - known_spans)]
        expanded, _ = expand_slots(text, apple + local, context, self.lexicon)
        slots = [{**slot, "options": sorted(slot["options"], key=lambda item: item[0])} for slot in expanded
                 if slot["options"] or (slot["start"], slot["end"]) in known_spans]
        return slots, apple_actions(apple)


class SegmentRequests(PreviewRequests):
    def __init__(self, executor, pending, key, context, lexicon):
        super().__init__(executor, pending, key, context, lexicon)
        self.previous = set()
        self.stable = set()
        self.sent = {}
        self.snapshots = []

    def observe(self, capture):
        if self.released is not None:
            return
        text = capture["text"]
        slots, _ = self.lexicon.prepare(capture, self.context)
        fragments = [fragment for fragment, complete in (fragment_for(text, slot) for slot in slots)
                     if complete and fragment.options]
        eligible = dict.fromkeys(fragment for fragment in fragments if fragment in self.previous)
        self.previous = set(fragments)
        self.stable.update(eligible)
        unsent = tuple(fragment for fragment in eligible if fragment not in self.sent)
        self.snapshots.append({"text": text, "eligible": len(eligible), "new": len(unsent)})
        self.pending.difference_update([future for future in self.pending if future.done()])
        if not unsent or len(self.requests) >= MAX_EARLY_REQUESTS or len(self.pending) >= MAX_EARLY_IN_FLIGHT:
            return
        query = Query("", [], questions=questions_for(unsent))
        future = self.executor.submit(query.run, self.key, self.context)
        self.pending.add(future)
        self.requests[unsent] = query, future
        self.sent.update(dict.fromkeys(unsent, (query, future)))

    def ready_answers(self, final_fragments, final_received):
        reusable = {}
        for fragment, questions in final_fragments.items():
            if fragment not in self.sent:
                continue
            query, future = self.sent[fragment]
            if not (future.done() and 0 < query.started_wall < self.released and query.finished <= final_received):
                continue
            try:
                answers = future.result()
            except RuntimeError:
                continue
            if questions.keys() <= answers.keys():
                reusable[fragment] = {name: answers[name] for name in questions}
        return reusable

    def audit(self):
        details = super().audit()
        for entry, fragments in zip(details, self.requests):
            entry.pop("preview")
            entry["fragments"] = [f.__dict__ for f in fragments]
        return details


def run_segment_pair(row, capture, final_received, preview, executor, polisher, key, context, lexicon):
    raw = capture["text"]
    row.update({"final_transcript": raw, "snapshots": preview.snapshots,
                "early_requests": sum(0 < q.started_wall < preview.released for q, _ in preview.requests.values())})
    if not raw.strip() or capture["finalize_ms"] > 550:
        row["skip"] = "local final unavailable within the 550 ms production budget"
        return

    slots, (flags, changes) = lexicon.prepare(capture, context)
    ordered = [fragment_for(raw, slot)[0] for slot in slots]
    final = {fragment: fragment.questions() for fragment in dict.fromkeys(ordered)}
    cached = preview.ready_answers(final, final_received)
    missing = [fragment for fragment in final if fragment not in cached]
    prepared = perf_counter()
    row["route"] = "all_cached" if cached and not missing else "partial_cache" if cached else "final_request"
    row["final_fragments"] = len(ordered)
    row["reused_fragments"] = sum(fragment in cached for fragment in ordered)
    row["final_candidate_fragments"] = sum(bool(fragment.options) for fragment in ordered)
    row["stable_final_matches"] = sum(fragment in preview.stable for fragment in ordered)
    row["sent_final_matches"] = sum(fragment in preview.sent for fragment in ordered)
    row["reused"] = [fragment.__dict__ for fragment in cached]

    serial = Query("", [], questions={name: q for questions in final.values() for name, q in questions.items()})
    residual = Query("", [], questions={name: q for fragment in missing for name, q in final[fragment].items()})
    futures = {}
    work = [serial, residual] if cached and missing else [serial]
    if row["sample"]["id"].endswith(("1", "3", "5", "7", "9")):
        work.reverse()
    for query in work:
        futures[id(query)] = executor.submit(query.run, key, context)

    def resolve(answers, complete):
        started = perf_counter()
        remapped = {f"{name[:4]}{index}": answers[name] for index, fragment in enumerate(ordered)
                    for name in final[fragment] if name in answers}
        marked, proposed = jev_actions(slots, remapped, flags, changes)
        staged = corrected(raw, slots, proposed, context)
        return marked, staged, 1000 * (max(prepared, complete) - final_received + perf_counter() - started)

    if cached:
        reused_answers = {name: answer for answers in cached.values() for name, answer in answers.items()}
        remaining_answers = futures[id(residual)].result() if missing else {}
        preview_result = resolve({**reused_answers, **remaining_answers}, residual.finished)
    serial_result = resolve(futures[id(serial)].result(), serial.finished)
    if not cached:
        preview_result = serial_result

    score_pair(row, capture, slots, (serial_result, preview_result), polisher)
    row["serial_jev_ms"] = serial.network_ms
    row["residual_jev_ms"] = residual.network_ms if cached else None


def summarize_segments(rows):
    for row in rows:
        row["held_previews"] = len(row["snapshots"])
    output = summarize(rows)
    paired = [row for row in rows if len(row["arms"]) == 2]
    for field in ("final_fragments", "reused_fragments", "final_candidate_fragments", "stable_final_matches", "sent_final_matches"):
        output[field] = sum(row[field] for row in paired)
    output["utterances_with_reuse"] = sum(bool(row["reused_fragments"]) for row in paired)
    output["residual_requests"] = sum(row["route"] == "partial_cache" for row in paired)
    output["early_fragments"] = sum(len(req["fragments"]) for row in rows for req in row["requests"]
                                    if req["started_from_release_ms"] < 0)
    output["routes"] = dict(Counter(row["route"] for row in paired))
    for name in ("same_text_while_held", "same_normalized_text_while_held", "same_request_while_held",
                 "same_request_after_release", "reuse_ready_at_final", "fallback_reasons", "last_held_preview_changed"):
        output.pop(name)
    return output
