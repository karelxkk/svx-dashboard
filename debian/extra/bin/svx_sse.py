#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SVX SSE bridge — CSV status přes SSE.
- SSE endpoint: /sse (SVX_SSE_PATH)
- TCP poke:     127.0.0.1:8091 (SVX_SSE_POKE_HOST, SVX_SSE_POKE_PORT)
- Po připojení: pošli celý status.csv (event: status_csv) a celou historii (event: history)
- Příkazy:
    status_full        → event: status_csv s celým status.csv
    status [LINK]      → event: status_csv_add s jedním CSV řádkem (změněný nebo daný LINK)
    history            → event: history_add s posledním řádkem history.csv
    both [LINK]        → status_csv_add + history_add
    send <ev> <data>   → přepošle událost
"""
import os
import io
import socket
import threading
import time
import re
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import List, Tuple, Dict, Optional

# ------------------------------ konfigurace ----------------------------
HOST = os.getenv("SVX_SSE_HOST", "127.0.0.1")
PORT = int(os.getenv("SVX_SSE_PORT", "8090"))
PATH = os.getenv("SVX_SSE_PATH", "/sse")
POKE_HOST = os.getenv("SVX_SSE_POKE_HOST", "127.0.0.1")
POKE_PORT = int(os.getenv("SVX_SSE_POKE_PORT", "8091"))

STATUS_CSV = os.getenv("SVX_STATUS_CSV", "/run/svxlink/status.csv")
HISTORY = os.getenv("SVX_HISTORY",    "/run/svxlink/history.csv")

CORS = os.getenv("SVX_SSE_CORS", "*")
HEARTBEAT = float(os.getenv("SVX_SSE_HEARTBEAT", "15"))
DELIM = os.getenv("SVX_CSV_DELIM", ";")

# ------------------------------ utilitky -------------------------------
STATUS_LOCK = threading.Lock()
LAST_SIG: Dict[str, Tuple[int, ...]] = {}

# status.csv: link;src;connected;talk_active;tg;last_change;last_talk_start;last_talk_stop;talk_last_duration
COLS = (
    "link", "src", "connected", "talk_active", "tg",
    "last_change", "last_talk_start", "last_talk_stop", "talk_last_duration",
)
SIG_KEYS = ("connected", "talk_active", "tg", "last_change",
            "last_talk_start", "last_talk_stop", "talk_last_duration")

REC_RE = re.compile(
    r"[0-9]{2}\.[0-9]{2}\.[0-9]{4} +[0-9]{2}:[0-9]{2}:[0-9]{2};[^;\n]+;[0-9]+;[0-9]+")


def read_text(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8", newline="") as f:
            return f.read()
    except Exception:
        return ""


def read_status_csv_text(path: str) -> str:
    return read_text(path)


def parse_status_csv(path: str) -> Dict[str, Dict[str, str]]:
    raw = read_text(path)
    if not raw:
        return {}
    lines = [ln for ln in raw.splitlines() if ln.strip()]
    if not lines:
        return {}
    # strip header if matches
    if lines and lines[0].lower().replace(" ", "") == DELIM.join(COLS).lower():
        lines = lines[1:]
    out: Dict[str, Dict[str, str]] = {}
    for ln in lines:
        parts = ln.split(DELIM)
        if len(parts) < len(COLS):
            continue
        row = {COLS[i]: parts[i] for i in range(len(COLS))}
        out[row["link"]] = row
    return out


def _row_sig(row: Dict[str, str]) -> Tuple[int, ...]:
    sig: List[int] = []
    for k in SIG_KEYS:
        v = row.get(k, "0")
        try:
            sig.append(int(float(v)))
        except Exception:
            sig.append(0)
    return tuple(sig)


def _row_ts(row: Dict[str, str]) -> int:
    t = 0
    for k in ("last_change", "last_talk_stop", "last_talk_start"):
        try:
            x = int(float(row.get(k, "0")))
        except Exception:
            x = 0
        if x > t:
            t = x
    return t


def update_sig_cache_from_file(path: str):
    global LAST_SIG
    rows = parse_status_csv(path)
    with STATUS_LOCK:
        LAST_SIG = {lk: _row_sig(r) for lk, r in rows.items()}


def compute_status_csv_add(path: str) -> Optional[str]:
    global LAST_SIG
    rows = parse_status_csv(path)
    if not rows:
        return None
    cur = {lk: _row_sig(r) for lk, r in rows.items()}
    changed: List[Tuple[str, Dict[str, str]]] = []
    with STATUS_LOCK:
        keys = set(cur.keys()) | set(LAST_SIG.keys())
        for k in keys:
            if cur.get(k) != LAST_SIG.get(k):
                r = rows.get(k)
                if r:
                    changed.append((k, r))
        if changed:
            lk, row = max(changed, key=lambda kv: _row_ts(kv[1]))
            LAST_SIG = cur
            return DELIM.join(row.get(c, "") for c in COLS)
        # fallback: nejnovější
        lk, row = max(rows.items(), key=lambda kv: _row_ts(kv[1]))
        LAST_SIG = cur
        return DELIM.join(row.get(c, "") for c in COLS)


def get_status_csv_for_link(path: str, link: str) -> Optional[str]:
    rows = parse_status_csv(path)
    row = rows.get(link)
    if not row:
        return None
    update_sig_cache_from_file(path)
    return DELIM.join(row.get(c, "") for c in COLS)


def read_history_text(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8", newline="") as f:
            raw = f.read()
        recs = REC_RE.findall(raw)
        if not recs:
            lines = [ln.strip() for ln in raw.splitlines() if ln.strip()]
            if lines and lines[0].lower().startswith("ts;"):
                lines = lines[1:]
            recs = lines
        return "\n".join(recs)
    except Exception:
        return ""


def read_last_history_line(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8", newline="") as f:
            raw = f.read()
        recs = REC_RE.findall(raw)
        if recs:
            return recs[-1]
        for line in reversed(raw.splitlines()):
            s = line.strip()
            if not s or s.lower().startswith("ts;"):
                continue
            return s
        return ""
    except Exception:
        return ""

# ------------------------------- broker --------------------------------


class Client:
    def __init__(self, qsize: int = 256):
        import queue
        self.q: "queue.Queue[Tuple[str, str]]" = queue.Queue(maxsize=qsize)
        self.alive = True

    def put(self, ev: str, data: str):
        if not self.alive:
            return
        try:
            if self.q.full():
                try:
                    self.q.get_nowait()
                except Exception:
                    pass
            self.q.put_nowait((ev, data))
        except Exception:
            self.alive = False


class Broker:
    def __init__(self):
        self._lock = threading.Lock()
        self._clients: List[Client] = []

    def register(self) -> Client:
        c = Client()
        with self._lock:
            self._clients.append(c)
        return c

    def unregister(self, c: Client):
        with self._lock:
            try:
                c.alive = False
                self._clients.remove(c)
            except ValueError:
                pass

    def broadcast(self, event: str, data: str):
        with self._lock:
            clients = list(self._clients)
        for c in clients:
            c.put(event, data)


BROKER = Broker()

# ------------------------------ HTTP SSE -------------------------------


class Handler(BaseHTTPRequestHandler):
    server_version = "SVX-SSE/csv-1.0"

    def log_message(self, fmt, *args):
        if os.getenv("SSE_VERBOSE"):
            try:
                super().log_message(fmt, *args)
            except Exception:
                pass

    def do_GET(self):
        if self.path.rstrip("/") != PATH.rstrip("/"):
            self.send_error(HTTPStatus.NOT_FOUND, "Not Found")
            return
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "keep-alive")
        self.send_header("X-Accel-Buffering", "no")
        if CORS:
            self.send_header("Access-Control-Allow-Origin", CORS)
        self.end_headers()

        c = BROKER.register()
        try:
            self._sse_comment("hello")
            st_csv = read_status_csv_text(STATUS_CSV)
            hi = read_history_text(HISTORY)
            if st_csv:
                self._sse_event("status_csv", st_csv)
                update_sig_cache_from_file(STATUS_CSV)
            if hi:
                self._sse_event("history", hi)
            self.wfile.flush()
            last_hb = time.monotonic()
            while c.alive:
                try:
                    ev, data = c.q.get(timeout=0.5)
                    self._sse_event(ev, data)
                except Exception:
                    pass
                now = time.monotonic()
                if now - last_hb >= HEARTBEAT:
                    self._sse_comment("hb")
                    last_hb = now
                    try:
                        self.wfile.flush()
                    except Exception:
                        break
        except Exception:
            pass
        finally:
            BROKER.unregister(c)

    def _sse_comment(self, txt: str):
        try:
            self.wfile.write(f": {txt}\n\n".encode("utf-8"))
        except Exception:
            pass

    def _sse_event(self, event: str, data: str):
        try:
            out = io.StringIO()
            if event:
                out.write(f"event: {event}\n")
            for line in str(data).split("\n") or [""]:
                out.write(f"data: {line}\n")
            out.write("\n")
            self.wfile.write(out.getvalue().encode("utf-8"))
        except Exception:
            pass

# ------------------------------- TCP poke ------------------------------


def process_line(line: str):
    parts = line.strip().split(" ", 2)
    cmd = parts[0].lower() if parts else ""
    arg = parts[1].strip() if len(parts) >= 2 else ""

    if cmd == "status_full":
        data = read_status_csv_text(STATUS_CSV)
        if data:
            BROKER.broadcast("status_csv", data)
            update_sig_cache_from_file(STATUS_CSV)
        return

    if cmd in ("status", "both"):
        if arg:
            row = get_status_csv_for_link(STATUS_CSV, arg)
        else:
            row = compute_status_csv_add(STATUS_CSV)
        if row:
            BROKER.broadcast("status_csv_add", row)

    if cmd in ("history", "both"):
        last = read_last_history_line(HISTORY)
        if last:
            BROKER.broadcast("history_add", last)

    if cmd == "send" and len(parts) >= 3:
        ev = parts[1]
        data = parts[2]
        BROKER.broadcast(ev, data)

# --------------------------------- main --------------------------------


class TcpPoke(threading.Thread):
    def __init__(self, host: str, port: int):
        super().__init__(daemon=True)
        self.host = host
        self.port = port

    def run(self):
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                s.bind((self.host, self.port))
                s.listen(16)
                while True:
                    conn, _ = s.accept()
                    threading.Thread(target=self.handle_conn,
                                     args=(conn,), daemon=True).start()
        except Exception:
            return

    def handle_conn(self, conn: socket.socket):
        try:
            with conn:
                conn.settimeout(2.0)
                buf = b""
                while True:
                    chunk = conn.recv(1024)
                    if not chunk:
                        break
                    buf += chunk
                    if b"\n" in buf:
                        break
                line = buf.decode("utf-8", "replace").strip()
                if not line:
                    return
                process_line(line)
        except Exception:
            return


def main():
    TcpPoke(POKE_HOST, POKE_PORT).start()
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    print(
        (
            f"svx-sse tcp={POKE_HOST}:{POKE_PORT} "
            f"http=http://{HOST}:{PORT}{PATH} hb={HEARTBEAT}s csv={STATUS_CSV}"
        ),
        flush=True,
    )
    try:
        httpd.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
