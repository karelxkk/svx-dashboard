#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SVX Reflector SSE bridge
- /events: Server-Sent Events stream
- Posílá eventy "status" (status.json) a "history" (posledních TAIL_LIMIT řádků history.csv; oddělovač ;) 
- Keepalive ping každých ~55 s
- Férové omezení klientů: globální MAX_CLIENTS + měkké per-IP (citlivé na CGNAT)
- Žádné externí moduly; polling změn souborů (mtime/size) v samostatném vlákně

Autor: OK1LBC
"""

import os
import sys
import time
import json
import threading
import signal
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from collections import deque

# ---------- Cesty a nastavení ----------
STATUS  = os.environ.get("SVX_STATUS",  "/dev/shm/svx/status.json")
HISTORY = os.environ.get("SVX_HISTORY", "/dev/shm/svx/history.csv")

TAIL_LIMIT = 28             # kolik záznamů historie posílat v "history" eventu
POLL_SEC   = 1.0            # frekvence kontroly změn souborů
KEEPALIVE_SEC = 55          # SSE ping, sladěné s ProxyTimeout u Apache (~65s)

BIND_HOST = os.environ.get("SVX_SSE_HOST", "127.0.0.1")
BIND_PORT = int(os.environ.get("SVX_SSE_PORT", "8890"))

# ---------- Férové limity ----------
# CGNAT-friendly: celkový strop a měkký per-IP práh, který se uplatní až při nedostatku
MAX_CLIENTS       = int(os.environ.get("SVX_SSE_MAX_CLIENTS", "300"))
RESERVE_FOR_OTHERS= int(os.environ.get("SVX_SSE_RESERVE", "30"))   # držet volné sloty
SOFT_PER_IP       = int(os.environ.get("SVX_SSE_SOFT_PER_IP", "50"))
HARD_PER_IP       = int(os.environ.get("SVX_SSE_HARD_PER_IP", "150"))

# ---------- Sdílené stavové proměnné ----------
RUN = True
LOCK = threading.RLock()

# id(wfile) -> (wfile, ip)
CLIENTS = {}
TOTAL = 0
CLIENTS_BY_IP = {}
ADM_LOCK = threading.Lock()

def log(*a):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    try:
        print(ts, *a, file=sys.stderr, flush=True)
    except Exception:
        pass

def _read_text(path):
    """Načti soubor jako text (utf-8). Při chybě vrať prázdný string."""
    try:
        with open(path, "rb") as f:
            b = f.read()
        return b.decode("utf-8", "replace")
    except Exception:
        return ""

def _tail_csv(path, n=TAIL_LIMIT):
    """Vrať JSON pole (text) s posledními n řádky CSV (start_ts;node;tg;dur).
       Při chybě vrať "[]".
    """
    try:
        dq = deque(maxlen=n)
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                s = line.strip()
                if s:
                    dq.append(s)
        out = []
        for s in dq:
            parts = s.split(";")
            if len(parts) >= 4:
                try:
                    start_ts = int(parts[0])
                except Exception:
                    continue
                node = parts[1]
                try:
                    tg = int(parts[2])
                except Exception:
                    tg = 0
                try:
                    dur = int(parts[3])
                except Exception:
                    dur = 0
                out.append({"start_ts": start_ts, "node": node, "tg": tg, "dur": dur})
        return json.dumps(out, separators=(",", ":"))
    except Exception:
        return "[]"

def _send(wfile, event, data_text):
    """Pošli jeden SSE event (už formátovaný JSON/řetězec) a flushni."""
    try:
        # Pozn.: data_text by mělo být single-line; pokud obsahuje \n, rozpadne se dle SSE specifikace do více data: řádků.
        # U nás posíláme JSON na jedné řádce.
        wfile.write(("event: %s\n" % event).encode("utf-8"))
        # SSE data řádek:
        # Pokud by data měly více řádků, rozdělíme a pošleme každý zvlášť:
        for ln in str(data_text).splitlines():
            wfile.write(("data: %s\n" % ln).encode("utf-8"))
        wfile.write(b"\n")
        wfile.flush()
        return True
    except Exception:
        return False

def _broadcast(event, text):
    """Pošli event všem klientům."""
    dead = []
    with LOCK:
        # snapshot kvůli bezpečnému průchodu
        items = list(CLIENTS.items())
    for key, (wfile, _ip) in items:
        ok = _send(wfile, event, text)
        if not ok:
            dead.append((key, _ip))
    if dead:
        with LOCK:
            for key, ip in dead:
                if key in CLIENTS:
                    try:
                        CLIENTS.pop(key, None)
                    except Exception:
                        pass
                _release(ip)

def _real_ip(handler):
    # přes Apache dostáváme X-Forwarded-For; vezmi první IP v seznamu
    try:
        xff = handler.headers.get("X-Forwarded-For")
        if xff:
            ip = xff.split(",")[0].strip()
            if ip:
                return ip
    except Exception:
        pass
    return handler.client_address[0]

def _claim(ip):
    """Zkus zarezervovat slot pro ip. True = povolit, False = odmítnout."""
    global TOTAL
    with ADM_LOCK:
        if TOTAL >= MAX_CLIENTS:
            return False
        c = CLIENTS_BY_IP.get(ip, 0)
        if c >= HARD_PER_IP:
            return False
        free = MAX_CLIENTS - TOTAL
        # měkký fair-share práh: pokud už má IP "hodně", nepouštěj, když by ukusoval z rezervy
        if c >= SOFT_PER_IP and free <= RESERVE_FOR_OTHERS:
            return False
        CLIENTS_BY_IP[ip] = c + 1
        TOTAL += 1
        return True

def _release(ip):
    global TOTAL
    with ADM_LOCK:
        c = CLIENTS_BY_IP.get(ip, 0)
        if c > 1:
            CLIENTS_BY_IP[ip] = c - 1
        else:
            CLIENTS_BY_IP.pop(ip, None)
        if TOTAL > 0:
            TOTAL -= 1

class Handler(BaseHTTPRequestHandler):
    server_version = "SVXSSE/1.0"

    def log_message(self, fmt, *args):
        # utlumené access logy; případně přepiš na syslog
        log("%s - %s" % (self.address_string(), fmt % args))

    def do_GET(self):
        if self.path != "/events":
            self.send_error(404)
            return

        ip = _real_ip(self)
        if not _claim(ip):
            self.send_response(429)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            try:
                self.wfile.write(b"Too Many Requests\n")
            except Exception:
                pass
            return

        try:
            # SSE hlavičky
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.end_headers()

            # standardní SSE hint pro klienta
            try:
                self.wfile.write(b"retry: 5000\n\n")
                self.wfile.flush()
            except Exception:
                raise

            # zaregistruj klienta
            with LOCK:
                CLIENTS[id(self.wfile)] = (self.wfile, ip)

            # po připojení hned pošli poslední známý status + historii
            s = _read_text(STATUS)
            if s:
                _send(self.wfile, "status", s)
            h = _tail_csv(HISTORY, TAIL_LIMIT)
            _send(self.wfile, "history", h)

            # keepalive smyčka (jen pingy; změny posílá broadcaster)
            last_ping = time.monotonic()
            while RUN:
                now = time.monotonic()
                if now - last_ping >= KEEPALIVE_SEC:
                    try:
                        self.wfile.write(b":keepalive\n\n")
                        self.wfile.flush()
                    except Exception:
                        break
                    last_ping = now
                time.sleep(0.2)
        finally:
            with LOCK:
                try:
                    CLIENTS.pop(id(self.wfile), None)
                except Exception:
                    pass
            _release(ip)

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

def _stat_sig(path):
    """Vrátí tuple (mtime_ns, size). Při chybě None."""
    try:
        st = os.stat(path)
        return (st.st_mtime_ns, st.st_size)
    except Exception:
        return None

def broadcaster():
    """Vlákno: hlídá změny souborů a vysílá eventy."""
    last_status = _stat_sig(STATUS)
    last_history = _stat_sig(HISTORY)
    log("Broadcaster started (STATUS=%s, HISTORY=%s)" % (STATUS, HISTORY))
    while RUN:
        try:
            time.sleep(POLL_SEC)
            cur = _stat_sig(STATUS)
            if cur != last_status and cur is not None:
                txt = _read_text(STATUS)
                if txt:
                    _broadcast("status", txt)
                last_status = cur

            curh = _stat_sig(HISTORY)
            if curh != last_history and curh is not None:
                arr = _tail_csv(HISTORY, TAIL_LIMIT)
                _broadcast("history", arr)
                last_history = curh
        except Exception as e:
            log("Broadcaster error:", e)
            time.sleep(1.0)

def handle_signals(server):
    # POZOR: server.shutdown() nesmí běžet ve stejném vlákně jako serve_forever,
    # jinak může dojít k deadlocku. Proto voláme shutdown v pomocném vlákně.
    def _stop(signum, frame):
        global RUN
        RUN = False
        try:
            threading.Thread(target=server.shutdown, name="shutdown", daemon=True).start()
        except Exception:
            pass
    for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(s, _stop)

def main():
    global RUN
    server = ThreadedHTTPServer((BIND_HOST, BIND_PORT), Handler)
    handle_signals(server)
    t = threading.Thread(target=broadcaster, name="broadcaster", daemon=True)
    t.start()
    log("Listening on http://%s:%d/events  (max=%d, soft/ip=%d, hard/ip=%d, reserve=%d)"
        % (BIND_HOST, BIND_PORT, MAX_CLIENTS, SOFT_PER_IP, HARD_PER_IP, RESERVE_FOR_OTHERS))
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        # Bezpecne zastaveni i mimo signal handler
        RUN = False
        try:
            server.shutdown()
        except Exception:
            pass
        try:
            server.server_close()
        except Exception:
            pass
        log("Server stopped.")

if __name__ == "__main__":
    main()
