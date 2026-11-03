"""把 CapsWriter 的识别包成 OpenAI 兼容的转写接口，给 ClawChat 的语音输入测试用。

ClawChat 只会说 OpenAI 的 `POST /v1/audio/transcriptions`，CapsWriter 是自有 WebSocket 协议（见 README「协议」），
这里在中间转一道：收 multipart 里的音频 → ffmpeg 解成 16kHz 单声道 float32 → 送给 CapsWriter → 回 {"text": ...}。
只用标准库，ITX 上装好 Python 就能跑，不用 pip。

    python transcribe_api.py [--port 6018] [--asr ws://127.0.0.1:6016] [--ffmpeg ffmpeg.exe] [--log server.log]

接口：
- POST /v1/audio/transcriptions：multipart，字段 file（必填）、model、prompt（当热词 context）、language（zh / en … 或 auto）、
  response_format（json 默认 / text / verbose_json）。鉴权头不看：服务只听本机，外面经 ssh 隧道进来。
- GET /v1/models：只有一个型号，名字带 transcribe，ClawChat 按名字认出这是转写模型。
- GET /health
"""
import argparse, base64, json, logging, os, re, socket, struct, subprocess, sys, tempfile, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

MODEL = "qwen3-asr-transcribe"
MAX_BODY = 25 << 20          # 和 OpenAI 一样，25MB
CHUNK = 16000 * 10           # 每帧送 10 秒音频
ASR_TIMEOUT = 120            # CapsWriter 单模型排队，长录音加上别人在用，给足

# OpenAI 用 ISO-639-1，CapsWriter 用小写英文全称（core/server/engines/language.py）；不认识的一律 auto
LANG = {
    "zh": "chinese", "en": "english", "yue": "cantonese", "ja": "japanese", "ko": "korean", "ar": "arabic",
    "de": "german", "fr": "french", "es": "spanish", "ru": "russian", "pt": "portuguese", "it": "italian",
}

log = logging.getLogger("transcribe")
args = None


# ---------- 送给 CapsWriter（最小的 WebSocket 客户端：只发文本帧、收文本帧） ----------

class WS:
    def __init__(self, url, timeout):
        u = urlparse(url)
        self.sock = socket.create_connection((u.hostname, u.port or 80), timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((
            f"GET {u.path or '/'} HTTP/1.1\r\nHost: {u.hostname}:{u.port}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
            "Sec-WebSocket-Protocol: binary\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            b = self.sock.recv(4096)
            if not b:
                raise ConnectionError("识别服务握手时断开")
            head += b
        head, _, self.buf = head.partition(b"\r\n\r\n")
        if b" 101 " not in head.split(b"\r\n")[0]:
            raise ConnectionError(f"识别服务握手失败：{head.splitlines()[0].decode(errors='replace')}")

    def send(self, text):
        data = text.encode()
        n = len(data)
        head = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else
                                bytes([0x80 | 126]) + struct.pack("!H", n) if n < 65536 else
                                bytes([0x80 | 127]) + struct.pack("!Q", n))
        mask = os.urandom(4)
        # 几 MB 的帧逐字节异或太慢，当成大整数一次异或
        full = (mask * (n // 4 + 1))[:n]
        masked = (int.from_bytes(data, "big") ^ int.from_bytes(full, "big")).to_bytes(n, "big") if n else b""
        self.sock.sendall(head + mask + masked)

    def _read(self, n):
        while len(self.buf) < n:
            b = self.sock.recv(65536)
            if not b:
                raise ConnectionError("识别服务断开了")
            self.buf += b
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def recv(self):
        parts = []
        while True:
            b0, b1 = self._read(2)
            op, n = b0 & 0x0F, b1 & 0x7F
            if n == 126:
                n = struct.unpack("!H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", self._read(8))[0]
            mask = self._read(4) if b1 & 0x80 else None
            payload = self._read(n)
            if mask:
                payload = bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
            if op == 8:
                raise ConnectionError("识别服务关了连接")
            if op == 9:   # ping → pong
                self.sock.sendall(bytes([0x8A, 0x80 | len(payload)]) + b"\0\0\0\0" + payload)
                continue
            if op == 10:
                continue
            parts.append(payload)
            if b0 & 0x80:
                return b"".join(parts).decode()

    def close(self):
        try:
            self.sock.sendall(bytes([0x88, 0x80]) + b"\0\0\0\0")
        except OSError:
            pass
        self.sock.close()


def recognize(pcm, context, language):
    """pcm 是 16kHz 单声道 float32 的原始字节。参数照 Mac 客户端完整识别那一路：分段 60 秒、重叠 4 秒"""
    tid = str(uuid.uuid4())
    t0 = time.time()

    def msg(data, final):
        return json.dumps(dict(task_id=tid, source="mic", data=data, is_final=final, time_start=t0,
                               seg_duration=60.0, seg_overlap=4.0, context=context, language=language))

    ws = WS(args.asr, ASR_TIMEOUT)
    try:
        step = CHUNK * 4
        for i in range(0, len(pcm), step):
            ws.send(msg(base64.b64encode(pcm[i:i + step]).decode(), False))
        ws.send(msg("", True))
        while True:
            m = json.loads(ws.recv())
            if m.get("task_id") == tid and m.get("is_final"):
                return m.get("text", "")
    finally:
        ws.close()


def decode(audio, filename):
    """m4a 的 moov 常在文件尾，从管道读不到，先落成临时文件"""
    suffix = os.path.splitext(filename or "")[1] or ".bin"
    fd, path = tempfile.mkstemp(suffix=suffix)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(audio)
        r = subprocess.run([args.ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-i", path,
                            "-f", "f32le", "-ac", "1", "-ar", "16000", "pipe:1"],
                           capture_output=True, timeout=60)
        if r.returncode != 0:
            raise ValueError(r.stderr.decode(errors="replace").strip() or f"ffmpeg 退出码 {r.returncode}")
        return r.stdout
    finally:
        os.remove(path)


# ---------- HTTP ----------

def parse_multipart(body, ctype):
    m = re.search(r'boundary="?([^";]+)"?', ctype)
    if not m:
        raise ValueError("multipart 缺 boundary")
    fields, files = {}, {}
    for part in body.split(b"--" + m.group(1).encode())[1:]:
        if part.startswith(b"--"):
            break
        head, _, data = part[2:].partition(b"\r\n\r\n")
        data = data[:-2] if data.endswith(b"\r\n") else data
        disp = next((l for l in head.decode(errors="replace").split("\r\n")
                     if l.lower().startswith("content-disposition")), "")
        name = re.search(r'\bname="([^"]*)"', disp)
        if not name:
            continue
        fn = re.search(r'filename="([^"]*)"', disp)
        if fn:
            files[name.group(1)] = (fn.group(1), data)
        else:
            fields[name.group(1)] = data.decode(errors="replace")
    return fields, files


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        log.debug("%s %s", self.address_string(), fmt % a)

    def reply(self, code, obj=None, text=None):
        body = (text if text is not None else json.dumps(obj, ensure_ascii=False)).encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8" if text is not None else "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def error(self, code, message, kind="invalid_request_error"):
        log.warning("%d %s", code, message)
        self.reply(code, {"error": {"message": message, "type": kind, "code": None}})

    def do_GET(self):
        path = urlparse(self.path).path.rstrip("/")
        if path in ("/v1/models", "/models"):
            self.reply(200, {"object": "list", "data": [
                {"id": MODEL, "object": "model", "created": 0, "owned_by": "nb-ime"}]})
        elif path == "/health":
            self.reply(200, {"status": "ok"})
        else:
            self.error(404, f"没有 {path}")

    def do_POST(self):
        path = urlparse(self.path).path.rstrip("/")
        if path not in ("/v1/audio/transcriptions", "/audio/transcriptions"):
            return self.error(404, f"没有 {path}")
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0 or n > MAX_BODY:
            return self.error(413 if n else 400, f"请求体 {n} 字节，要在 1～{MAX_BODY} 之间")
        body = self.rfile.read(n)
        ctype = self.headers.get("Content-Type", "")
        if not ctype.startswith("multipart/form-data"):
            return self.error(400, "要 multipart/form-data")
        try:
            fields, files = parse_multipart(body, ctype)
        except ValueError as e:
            return self.error(400, str(e))
        if "file" not in files:
            return self.error(400, "缺 file 字段")
        filename, audio = files["file"]
        lang = LANG.get(fields.get("language", "").strip().lower().split("-")[0], "auto")
        context = fields.get("prompt", "").strip()
        fmt = fields.get("response_format", "json")
        t0 = time.time()
        try:
            pcm = decode(audio, filename)
        except (ValueError, subprocess.TimeoutExpired) as e:
            return self.error(400, f"音频解不开：{e}")
        secs = len(pcm) / 4 / 16000
        t1 = time.time()
        try:
            text = recognize(pcm, context, lang)
        except (OSError, ConnectionError, ValueError) as e:
            return self.error(502, f"识别服务出错：{e}", "server_error")
        t2 = time.time()
        log.info("%s %.1f 秒音频（%s，%d 字节）解码 %.2fs 识别 %.2fs，model=%s language=%s 热词 %d 字：%s",
                 self.address_string(), secs, filename, len(audio), t1 - t0, t2 - t1,
                 fields.get("model", ""), lang, len(context), text)
        if fmt == "text":
            self.reply(200, text=text)
        elif fmt == "verbose_json":
            self.reply(200, {"task": "transcribe", "language": lang, "duration": round(secs, 2), "text": text})
        else:
            self.reply(200, {"text": text})


def main():
    global args
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1")   # 只听本机，客户端走 ssh 隧道
    p.add_argument("--port", type=int, default=6018)
    p.add_argument("--asr", default="ws://127.0.0.1:6016")
    p.add_argument("--ffmpeg", default="ffmpeg")
    p.add_argument("--log")
    args = p.parse_args()
    handlers = [logging.StreamHandler(sys.stderr)]
    if args.log:
        handlers.append(logging.FileHandler(args.log, encoding="utf-8"))
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", handlers=handlers)
    log.info("监听 %s:%d → %s，ffmpeg=%s", args.host, args.port, args.asr, args.ffmpeg)
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
