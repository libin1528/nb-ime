"""Install the optional single-stream preview hook into CapsWriter v2.6 while stopped."""
import argparse
from pathlib import Path
import shutil


def install(root):
    folder = root / "core/server/connection"
    path = folder / "ws_recv.py"
    old = path.read_bytes()
    src = old.decode("utf-8")
    if "from .dictation_preview import submit_preview" not in src:
        edits = [
            ("from ..schema import Task", "from ..schema import Task\nfrom .dictation_preview import submit_preview"),
            ("cache: AudioCache, app) -> None:", "cache: AudioCache, app, preview=None) -> None:"),
            ("cache.byte_count += len(data)", "cache.byte_count += len(data)\n        if preview:\n            submit_preview(preview, msg, cache, socket_id, queue_in)"),
            ("await message_handler(websocket, msg, cache, app)", 'await message_handler(websocket, msg, cache, app, data.get("nb_preview"))'),
        ]
        for before, after in edits:
            if src.count(before) != 1:
                raise ValueError(f"Unrecognized CapsWriter receiver: {before}")
            src = src.replace(before, after.replace("\n", "\r\n" if "\r\n" in src else "\n"))
        backup = path.with_suffix(".py.before-nb-preview")
        if not backup.exists():
            backup.write_bytes(old)
    compile(src, str(path), "exec")
    module = folder / "dictation_preview.py"
    shutil.copyfile(Path(__file__).with_name(module.name), module.with_suffix(".pending"))
    module.with_suffix(".pending").replace(module)
    if src.encode() != old:
        temp = path.with_suffix(".pending")
        temp.write_bytes(src.encode())
        temp.replace(path)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capswriter", type=Path)
    install(parser.parse_args().capswriter)
