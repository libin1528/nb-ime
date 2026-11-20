import unittest
from concurrent.futures import Future, ThreadPoolExecutor
from time import perf_counter, time
from unittest.mock import patch

from preview import Query
from segment_preview import SegmentRequests, fragment_for, run_segment_pair, summarize_segments
from test_preview import EchoPolisher


def slot_for(text, word, options):
    start = text.index(word)
    return {"start": start, "end": start + len(word), "original": word,
            "options": [(value, None) for value in options], "confidence": None}


class SegmentPreviewTests(unittest.TestCase):
    def test_only_local_context_and_candidate_content_define_reuse(self):
        text = "今天请打开圆点进行检查"
        original, complete = fragment_for(text, slot_for(text, "圆", ["原"]))
        self.assertTrue(complete)
        distant_change = "明天请打开圆点进行另外一项检查"
        same_window, _ = fragment_for(distant_change, slot_for(distant_change, "圆", ["原"]))
        self.assertEqual(original.questions(), same_window.questions())
        for changed, alternatives in (("今天请点开圆点进行检查", ["原"]), (text, ["元"])):
            fragment, _ = fragment_for(changed, slot_for(changed, "圆", alternatives))
            self.assertNotEqual(original, fragment)
            self.assertTrue(original.questions().keys().isdisjoint(fragment.questions()))

    def test_partial_cache_only_requests_missing_fragments(self):
        raw = "今天请打开圆点再检查功能"
        slots = [slot_for(raw, "圆", ["原"]), slot_for(raw, "功", ["工"])]
        first, second = (fragment_for(raw, slot)[0] for slot in slots)

        class FixedLexicon:
            def prepare(self, capture, context):
                return slots, (set(), {})

        lexicon = FixedLexicon()
        context = {"hotwords": [], "rules": []}
        preview = SegmentRequests(None, set(), "test", context, lexicon)
        release = time()
        preview.release(release, perf_counter())
        early = Query("", [], started_wall=release - 1, finished=perf_counter() - 0.1)
        cached = Future()
        cached.set_result({name: {"noul": 0.95} if name.startswith("flag") else
                           {"choice": "alt0", "probabilities": {"alt0": 0.99}, "confidence": 0.99}
                           for name in first.questions()})
        preview.sent[first] = early, cached
        pending = Future()
        preview.sent[second] = early, pending
        capture = {"text": raw, "release_ms": 400, "finalize_ms": 150}
        row = {"sample": {"id": "p01", "ref": raw.replace("圆", "原"), "target": "原点"}, "arms": {}}
        with ThreadPoolExecutor(2) as executor, patch("preview.request_jev", return_value=({}, 0)) as request:
            run_segment_pair(row, capture, perf_counter(), preview, executor, EchoPolisher(), "test", context, lexicon)
        self.assertEqual(row["route"], "partial_cache")
        self.assertEqual(row["reused_fragments"], 1)
        self.assertEqual(row["arms"]["preview"]["staged"], raw.replace("圆", "原"))
        self.assertEqual(row["arms"]["serial"]["staged"], raw)
        sent = [set(call.args[1]) for call in request.call_args_list]
        self.assertCountEqual(sent, [set(second.questions()), first.questions().keys() | second.questions().keys()])
        row["requests"] = []
        totals = summarize_segments([row])
        self.assertEqual(totals["final_fragments"], 2)
        self.assertEqual(totals["reused_fragments"], 1)

    def test_requires_matching_fragment_on_two_preview_updates(self):
        text = "今天请打开圆点进行检查"
        slots = [slot_for(text, "圆", ["原"])]

        class FixedLexicon:
            def prepare(self, capture, context):
                return slots, (set(), {})

        with ThreadPoolExecutor(1) as executor, patch("preview.request_jev", return_value=({}, 0)) as request:
            preview = SegmentRequests(executor, set(), "test", {}, FixedLexicon())
            preview.observe({"text": text})
            self.assertEqual(len(preview.requests), 0)
            preview.observe({"text": text})
            preview.observe({"text": text})
        self.assertEqual(len(preview.requests), 1)
        self.assertEqual(request.call_count, 1)
