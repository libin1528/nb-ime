"""Keep spoken clock times intact during CapsWriter's number conversion."""

import re
from collections.abc import Callable

_DIGITS = {digit: value for value, digit in enumerate("零一二三四五六七八九")}
_DIGITS["两"] = 2
_NUMBER = "零〇一二两三四五六七八九十百千万亿点點.0-9"
_CLOCK = re.compile(
    rf"(?<![{_NUMBER}])"
    r"(?P<weekday>(?:周|星期|礼拜)[一二三四五六日天])?"
    r"(?P<hour>[一二两三四五六七八九]|十[一二三四五六七八九]?|二十[一二三]?)点"
    rf"(?P<minute>[二三四五]?十[一二三四五六七八九]?)(?![{_NUMBER}])"
)
_NON_CLOCK_PREFIX = re.compile(r"(?:版本(?:号)?|版号|[vV])\s*$")
_NON_CLOCK_SUFFIXES = (
    "分", "倍", "度", "个", "万", "亿", "元", "块", "百分", "%", "％", "公斤",
    "千克", "克", "斤", "米", "升", "秒", "小时", "版",
)


def _integer(text: str) -> int:
    if "十" not in text:
        return _DIGITS[text]
    tens, ones = text.split("十")
    return _DIGITS.get(tens, 1) * 10 + _DIGITS.get(ones, 0)


def normalize_clock_numbers(text: str, normalize_numbers: Callable[[str], str]) -> str:
    """Preserve 点 in times such as 一点二十五 where the speaker omits 分."""
    parts = []
    cursor = 0
    for match in _CLOCK.finditer(text):
        before = text[:match.start()]
        after = text[match.end():].lstrip()
        if _NON_CLOCK_PREFIX.search(before) or after.startswith(_NON_CLOCK_SUFFIXES):
            continue
        if before.endswith(("周", "星期", "礼拜")):
            continue
        parts.append(normalize_numbers(text[cursor:match.start()]))
        weekday = match["weekday"] or ""
        hour = _integer(match["hour"])
        minute = _integer(match["minute"])
        parts.append(f"{weekday}{hour}点{minute:02d}")
        cursor = match.end()
    if not parts:
        return normalize_numbers(text)
    parts.append(normalize_numbers(text[cursor:]))
    return "".join(parts)
