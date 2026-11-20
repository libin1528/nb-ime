"""Local candidate generation from the hotword list and a general Mandarin lexicon."""

from collections import defaultdict
from difflib import SequenceMatcher
from os.path import commonprefix
from pathlib import Path
import re

import jieba
from pypinyin import Style, lazy_pinyin


HAN = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff]+")
LATIN_WORD = re.compile(r"[A-Za-z]{5,}")
MIN_FREQUENCY = 50
MAX_HOMOPHONES = 3


def reading(text, style):
    return tuple(lazy_pinyin(text, style=style, neutral_tone_with_five=True))


def similar_latin_word(left, right):
    if not LATIN_WORD.fullmatch(right):
        return False
    left, right = left.lower(), right.lower()
    prefix = len(commonprefix([left, right]))
    return (SequenceMatcher(None, left, right, autojunk=False).ratio() >= 0.8
            or (prefix >= 4 and prefix >= min(len(left), len(right)) - 1 and abs(len(left) - len(right)) <= 3))


class CandidateLexicon:
    def __init__(self, hotwords):
        self.mandarin_hotwords = defaultdict(list)
        self.latin_hotwords = []
        for word in hotwords:
            if len(word) >= 2 and HAN.fullmatch(word):
                self.mandarin_hotwords[len(word), reading(word, Style.NORMAL)].append(word)
            elif LATIN_WORD.fullmatch(word):
                self.latin_hotwords.append(word)
        self.hotword_lengths = sorted({length for length, _ in self.mandarin_hotwords}, reverse=True)

        entries = defaultdict(list)
        with Path(jieba.__file__).with_name("dict.txt").open(encoding="utf-8") as dictionary:
            for line in dictionary:
                word, frequency, *_ = line.split()
                frequency = int(frequency)
                if frequency >= MIN_FREQUENCY and len(word) <= 4 and HAN.fullmatch(word):
                    entries[reading(word, Style.TONE3)].append((frequency, word))
        self.homophones = {key: [word for _, word in sorted(values, reverse=True)] for key, values in entries.items()}

    def proposals(self, text, slots):
        for match in HAN.finditer(text):
            for size in self.hotword_lengths:
                for start in range(match.start(), match.end() - size + 1):
                    end = start + size
                    phrase = text[start:end]
                    for word in self.mandarin_hotwords.get((size, reading(phrase, Style.NORMAL)), ()):
                        yield start, end, word, "mandarin_hotword"

        for slot in slots:
            fragment = slot["original"]
            if LATIN_WORD.fullmatch(fragment):
                spellings = [fragment] + [value for value, _ in slot["options"]]
                for word in self.latin_hotwords:
                    if any(similar_latin_word(word, spelling) for spelling in spellings):
                        yield slot["start"], slot["end"], word, "latin_hotword"

            if HAN.fullmatch(fragment) and len(fragment) <= 4:
                existing = {fragment} | {value for value, _ in slot["options"]}
                words = [word for word in self.homophones.get(reading(fragment, Style.TONE3), ())
                         if word not in existing]
                for word in words[:MAX_HOMOPHONES]:
                    yield slot["start"], slot["end"], word, "homophone"
