"""Range-capable HTTP server that breaks on purpose, to test how the player recovers.

usage: python flaky_server.py FILE PORT MODE [--fault-at BYTES] [--slow-rate BYTES] [--tls CERT KEY]

each fault happens once, when a response reaches byte FAULT_AT of the file, whatever the
client's request size is:
  ok         no faults
  close      the connection is reset there (tcp rst, a CDN dropping connections)
  fin        the connection is closed cleanly there: the client sees an early end of data
  close503   like close, and the reconnection gets a 503 (what Real-Debrid does)
  503        like fin, and the reconnection gets a 503 (a request that starts past FAULT_AT
             before anything broke gets the 503 directly)
  stall      the server stops sending there and keeps the connection open (a hung connection)
  slow       from there that response trickles at --slow-rate bytes/s, below the video's bitrate, and
             stays open (a congested cdn node). new connections get full speed
  slowall    every response trickles at --slow-rate from its first byte (a slow server or line):
             reconnecting can't help
  maxage     any response open for more than 20 s is reset (not limited to once)
  idleclose  the connection is closed if the client stops reading for 5 s (full buffer)

with --tls it serves https with that certificate and key (pem), for the certificate checks.

every fault is logged on a line starting with FAULT, so a runner can check it really happened.
"""
import argparse
import http.server
import os
import socket
import ssl
import struct
import threading
import time

MODES = ("ok", "close", "fin", "close503", "503", "stall", "slow", "slowall", "maxage", "idleclose")
AT_OFFSET = ("close", "fin", "close503", "503", "stall", "slow")

ap = argparse.ArgumentParser()
ap.add_argument("file")
ap.add_argument("port", type=int)
ap.add_argument("mode", choices=MODES)
ap.add_argument("--fault-at", type=int, default=10 * 1024 * 1024)
ap.add_argument("--slow-rate", type=int, default=24 * 1024)
ap.add_argument("--tls", nargs=2, metavar=("CERT", "KEY"))
args = ap.parse_args()

size = os.path.getsize(args.file)
lock = threading.Lock()
state = {"n": 0, "fired": False, "pending503": False}


def log(msg):
    print(f"{time.strftime('%H:%M:%S')} {msg}", flush=True)


def take_fault():
    with lock:
        if state["fired"]:
            return False
        state["fired"] = True
        return True


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def handle(self):
        try:
            super().handle()
        except ssl.SSLError as e:
            log(f"tls: {e.reason or e}")
        except OSError:
            pass

    def reset(self):
        # linger 0 makes close() send a rst instead of a fin
        self.close_connection = True
        self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        self.connection.close()

    def parse_range(self):
        rng = self.headers.get("Range")
        if not rng or not rng.startswith("bytes="):
            return None, 0, size - 1
        a, b = rng[6:].split(",")[0].split("-")
        if a == "":
            return rng, max(0, size - int(b)), size - 1
        return rng, int(a), min(int(b) if b else size - 1, size - 1)

    def send_status_only(self, code, extra=()):
        self.send_response(code)
        for k, v in extra:
            self.send_header(k, v)
        self.send_header("Content-Length", "0")
        self.end_headers()
        self.close_connection = False   # see the end of do_GET

    def send_headers_for(self, rng, start, end):
        self.send_response(206 if rng else 200)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Type", "video/x-matroska")
        self.send_header("Content-Length", str(end - start + 1))
        if rng:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()

    def do_HEAD(self):
        self.send_headers_for(*self.parse_range())

    def do_GET(self):
        with lock:
            state["n"] += 1
            n = state["n"]
            pending503 = state["pending503"]
            state["pending503"] = False
        rng, start, end = self.parse_range()
        log(f"req {n} range {start}-{end}")
        mode = args.mode
        if start >= size:
            self.send_status_only(416, [("Content-Range", f"bytes */{size}")])
            return
        if pending503 or (mode == "503" and start >= args.fault_at and take_fault()):
            log(f"FAULT req {n} -> 503")
            self.send_status_only(503, [("Retry-After", "1")])
            return
        self.send_headers_for(rng, start, end)
        if mode == "idleclose":
            self.connection.settimeout(5)
        pos, t0 = start, time.time()
        slow = mode == "slowall"
        if slow and take_fault():
            log(f"FAULT req {n} -> every response slowed to {args.slow_rate} bytes/s")
        try:
            with open(args.file, "rb") as f:
                f.seek(start)
                while pos <= end:
                    want = min(4096 if slow else 65536, end - pos + 1)
                    if pos < args.fault_at:
                        want = min(want, args.fault_at - pos)
                    chunk = f.read(want)
                    self.wfile.write(chunk)
                    pos += len(chunk)
                    if slow:
                        time.sleep(len(chunk) / args.slow_rate)
                    if mode == "maxage" and time.time() - t0 > 20:
                        log(f"FAULT req {n} -> recycled after {pos - start} bytes")
                        self.reset()
                        return
                    if pos != args.fault_at or mode not in AT_OFFSET or not take_fault():
                        continue
                    if mode == "slow":
                        log(f"FAULT req {n} -> slowed to {args.slow_rate} bytes/s at byte {pos}")
                        slow = True
                        continue
                    if mode in ("close503", "503"):
                        with lock:
                            state["pending503"] = True
                    if mode in ("close", "close503"):
                        log(f"FAULT req {n} -> reset at byte {pos}")
                        self.reset()
                    elif mode in ("fin", "503"):
                        # fin first, then a full close like a real server (a half-open socket would
                        # leave the client waiting on some setups)
                        log(f"FAULT req {n} -> clean close at byte {pos}")
                        self.connection.shutdown(socket.SHUT_WR)
                        self.close_connection = True
                    else:
                        log(f"FAULT req {n} -> stalled at byte {pos}")
                        self.close_connection = True
                        time.sleep(3600)
                    return
            log(f"req {n} -> complete")
            # leave the closing to the client even if it asked for "Connection: close": on windows a
            # server-side close right after the last byte can reach the client as a reset before it
            # has read everything, which would add a fault nobody asked for
            self.close_connection = False
        except TimeoutError:
            log(f"FAULT req {n} -> idle close after {pos - start} bytes")
            self.close_connection = True
        except OSError as e:
            log(f"req {n} -> client gone after {pos - start} bytes ({e.__class__.__name__})")
            self.close_connection = True


server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
server.daemon_threads = True
if args.tls:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(*args.tls)
    # the handshake happens in the handler thread, so a client that fails it can't block accept()
    server.socket = ctx.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
log(f"{'https' if args.tls else 'http'}: serving {os.path.basename(args.file)} ({size} bytes) on port {args.port}, mode {args.mode}, faults at byte {args.fault_at}")
server.serve_forever()
