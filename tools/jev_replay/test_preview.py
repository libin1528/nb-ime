import unittest
from concurrent.futures import Future, ThreadPoolExecutor
from time import perf_counter, time
from unittest.mock import patch

from preview import PreviewRequests, Query, prepare, run_pair, signature


class EmptyLexicon:
    def proposals(self, text, slots):
        return ()


class EchoPolisher:
    def run(self, text):
        return {"text": text, "prepared": text, "replace_hits": [], "note": "test", "ms": 0}


def candidate(text):
    return {"text": text, "runs": []}


class PreviewReuseTests(unittest.TestCase):
    def run_case(self, preview_text, preview_alternatives, starts_after_release=False):
        raw = "请打开圆点"
        sample = {"id": "p01", "ref": "请打开原点", "target": "原点"}
        context = {"hotwords": [], "rules": []}
        lexicon = EmptyLexicon()
        capture = {"text": raw, "release_ms": 400, "finalize_ms": 150,
                   "segments": [{"primary": candidate(raw), "alternatives": [candidate(sample["ref"])]}]}
        provisional = {"text": preview_text, "segments": [
            {"primary": candidate(preview_text), "alternatives": [candidate(text) for text in preview_alternatives]}]}
        provisional_slots, _ = prepare(provisional, context, lexicon)
        tag = signature(preview_text, provisional_slots)
        release = time()
        query = Query(preview_text, provisional_slots, started_wall=release + (1 if starts_after_release else -1),
                      finished=perf_counter() - 0.1)
        early_reply = Future()
        early_reply.set_result({"pick0": {"choice": "alt0", "probabilities": {"alt0": 0.99}, "confidence": 0.99}})
        row = {"sample": sample, "arms": {}}
        with ThreadPoolExecutor(1) as serial:
            preview = PreviewRequests(None, set(), "test", context, lexicon)
            preview.observed.append((tag, perf_counter() - 0.5, True))
            preview.requests[tag] = query, early_reply
            preview.release(release, perf_counter())
            with patch("preview.ask_jev", return_value=({}, 0)):
                run_pair(row, capture, perf_counter(), preview, serial, EchoPolisher(), "test", context, lexicon)
        return row

    def test_identical_request_started_before_release_reuses_answer(self):
        row = self.run_case("请打开圆点", ["请打开原点"])
        self.assertEqual(row["route"], "reuse")
        self.assertTrue(row["reuse_ready_at_final"])
        self.assertEqual(row["arms"]["preview"]["staged"], "请打开原点")
        self.assertEqual(row["arms"]["serial"]["staged"], "请打开圆点")

    def test_stale_or_late_answer_cannot_change_final(self):
        for text, alternatives, late, reason in (
            ("打开圆点", ["打开原点"], False, "transcript_changed"),
            ("请打开圆点", ["请打开元点"], False, "slots_or_candidates_changed"),
            ("请打开圆点", ["请打开原点"], True, "matching_request_not_started_before_release"),
        ):
            with self.subTest(reason=reason):
                row = self.run_case(text, alternatives, late)
                self.assertEqual(row["route"], "final_request")
                self.assertEqual(row["fallback_reason"], reason)
                self.assertEqual(row["arms"]["preview"], row["arms"]["serial"])
