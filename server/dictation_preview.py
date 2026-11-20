"""Submit a bounded draft from an existing CapsWriter v2.6 microphone buffer."""
import time

from ..schema import Task


def submit_preview(request, msg, cache, socket_id, queue):
    if not isinstance(request, dict) or msg.is_final or msg.source != "mic":
        return
    start, end = request.get("start"), request.get("end")
    if type(start) is not int or type(end) is not int:
        return
    if start < 0 or end * 4 != cache.byte_count or end <= start:
        return
    draft_id = f"{msg.task_id}/preview/{end}"
    if request.get("id") != draft_id:
        return
    # For long recordings the official stream may already have advanced its window.
    base = (cache.byte_count - len(cache.chunks)) // 4
    start = max(base, start, end - 12 * 16000)
    if start >= end:
        return
    queue.put(Task(type="mic", data=cache.chunks[(start-base)*4:], offset=0, overlap=0,
                   task_id=draft_id, socket_id=socket_id, is_final=True,
                   time_start=msg.time_start, time_submit=time.time(),
                   context=msg.context, language=msg.language))
