#!/usr/bin/env python3
"""A stand-in for a vLLM server with Sleep Mode, for testing probe.sh without a GPU.

It implements /health, /version, /v1/models, /v1/completions, /sleep,
/wake_up (with tags), /is_sleeping and /collective_rpc. After a level 2 sleep
the weights are gone: completions return garbage until reload_weights runs,
which mirrors real vLLM.

Usage: python3 mock_vllm.py [--port 18001]
"""

import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

STATE = {"sleeping": False, "level": 0, "weights_ok": True, "weights_mapped": True, "kv_mapped": True}
MODEL = "mock/model"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/health":
            self.reply(200, {})
        elif path == "/version":
            self.reply(200, {"version": "mock-0.0"})
        elif path == "/v1/models":
            self.reply(200, {"object": "list", "data": [{"id": MODEL, "object": "model"}]})
        elif path == "/is_sleeping":
            self.reply(200, {"is_sleeping": STATE["sleeping"]})
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}") if length else {}

        if url.path == "/v1/completions":
            if STATE["sleeping"] or not (STATE["weights_mapped"] and STATE["kv_mapped"]):
                self.reply(503, {"error": "model is sleeping"})
                return
            text = " Paris. It is also" if STATE["weights_ok"] else " #$%@ garbage"
            self.reply(200, {"choices": [{"index": 0, "text": text, "finish_reason": "length"}]})
        elif url.path == "/sleep":
            level = int(query.get("level", ["1"])[0])
            STATE.update(sleeping=True, level=level, weights_mapped=False, kv_mapped=False)
            if level == 2:
                STATE["weights_ok"] = False
            self.reply(200, {})
        elif url.path == "/wake_up":
            tags = query.get("tags")
            if not tags or "weights" in tags:
                STATE["weights_mapped"] = True
            if not tags or "kv_cache" in tags:
                STATE["kv_mapped"] = True
            STATE["sleeping"] = not (STATE["weights_mapped"] and STATE["kv_mapped"])
            self.reply(200, {})
        elif url.path == "/collective_rpc":
            if body.get("method") == "reload_weights" and STATE["weights_mapped"]:
                STATE["weights_ok"] = True
                self.reply(200, {"results": [None]})
            else:
                self.reply(400, {"error": "weights not mapped"})
        else:
            self.reply(404, {"error": "not found"})


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=18001)
    args = p.parse_args()
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
