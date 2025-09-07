#!/usr/bin/env python3
import os, time, json
from http.server import HTTPServer, BaseHTTPRequestHandler
STATUS=os.environ.get("SVX_STATUS","/run/svxlink/status.json")
HISTORY=os.environ.get("SVX_HISTORY","/run/svxlink/history.csv")
LOCK=os.path.join(os.environ.get("SVX_LOCKDIR","/run/lock/svxlink"),"history.lock")
LIMIT=int(os.environ.get("SVX_HISTORY_LIMIT","28"))
HOST=os.environ.get("SVX_SSE_HOST","0.0.0.0"); PORT=int(os.environ.get("SVX_SSE_PORT","8078"))
def wait_unlock(ms=250):
    dl=time.monotonic()+ms/1000.0
    while os.path.exists(LOCK) and time.monotonic()<dl: time.sleep(0.01)
def sanitize(txt):
    try:
        o=json.loads(txt); n=o.get("nodes")
        if isinstance(n,dict):
            for k,v in n.items():
                if isinstance(v,dict): v.pop("talk_count",None)
        return json.dumps(o,separators=(',',':'))
    except: return txt
def tail_csv(p,n=LIMIT):
    try:
        with open(p,"r",encoding="utf-8") as f:
            rows=f.read().splitlines()[1:]
        return rows[-n:]
    except: return []
def evt(t,d): return f"event: {t}\ndata: {d}\n\n".encode()
class H(BaseHTTPRequestHandler):
    def log_message(self,*a,**k): pass
    def do_GET(self):
        if self.path!="/sse": self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header("Content-Type","text/event-stream; charset=utf-8")
        self.send_header("Cache-Control","no-cache"); self.send_header("Connection","keep-alive"); self.end_headers()
        wait_unlock()
        try:
            st=sanitize(open(STATUS,"r",encoding="utf-8").read() if os.path.exists(STATUS) else "{}")
        except: st="{}"
        self.wfile.write(evt("status",st))
        self.wfile.write(evt("history",json.dumps(tail_csv(HISTORY),ensure_ascii=False))); self.wfile.flush()
        sm=os.path.getmtime(STATUS) if os.path.exists(STATUS) else 0
        hm=os.path.getmtime(HISTORY) if os.path.exists(HISTORY) else 0
        while True:
            time.sleep(1.0)
            m=os.path.getmtime(STATUS) if os.path.exists(STATUS) else 0
            if m!=sm:
                sm=m
                try: self.wfile.write(evt("status",sanitize(open(STATUS,"r",encoding="utf-8").read()))); self.wfile.flush()
                except: break
            m=os.path.getmtime(HISTORY) if os.path.exists(HISTORY) else 0
            if m!=hm:
                hm=m; wait_unlock()
                try: self.wfile.write(evt("history",json.dumps(tail_csv(HISTORY),ensure_ascii=False))); self.wfile.flush()
                except: break
def run(): HTTPServer((HOST,PORT),H).serve_forever()
if __name__=="__main__": run()
