#!/usr/bin/env python3
"""LM-Switchyard M0: hold-test server.

A fake OpenAI-compatible endpoint that holds each request before answering, to
check whether an agent (for example Hermes) tolerates the wait the JIT gateway
imposes while a model loads.

Models it offers:
  lmsy-hold-keepalive  waits --hold seconds while sending keepalives:
                       SSE comment lines when streaming, spaces before the JSON
                       body when not streaming
  lmsy-hold-silent     waits --hold seconds and sends nothing until the answer
  lmsy-instant         answers immediately (control)

Every request is logged as a JSON line with its shape only: path, model, stream
flag, body keys, and selected headers. Message content and the Authorization
value are never logged.

Usage:
  python3 hold_server.py [--port 18100] [--hold 90] [--interval 5] [--log hold-test.log]
"""

import argparse
import json
import select
import socket
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODELS = ["lmsy-hold-keepalive", "lmsy-hold-silent", "lmsy-instant"]
LOGGED_HEADERS = ("user-agent", "x-session-id", "session-id", "x-request-id", "x-client-request-id")
LOGGED_HEADER_PREFIXES = ("x-stainless-", "x-hermes", "openai-")

ARGS = None
LOG_LOCK = threading.Lock()


def log(record):
    record["ts"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    line = json.dumps(record, ensure_ascii=False)
    with LOG_LOCK:
        with open(ARGS.log, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    print(line, flush=True)


class Disconnected(Exception):
    pass


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "lmsy-hold-test/0.1"

    def log_message(self, fmt, *args):  # silence the default access log
        pass

    # ------------------------------------------------------------ helpers

    def request_shape(self, body):
        headers = {k.lower(): v for k, v in self.headers.items()}
        picked = {k: v for k, v in headers.items()
                  if k in LOGGED_HEADERS or k.startswith(LOGGED_HEADER_PREFIXES)}
        shape = {
            "event": "request",
            "client": self.client_address[0],
            "method": self.command,
            "path": self.path,
            "header_names": sorted(headers.keys()),
            "headers": picked,
            "authorization_present": "authorization" in headers,
        }
        if isinstance(body, dict):
            shape.update({
                "model": body.get("model"),
                "stream": body.get("stream", False),
                "stream_options": body.get("stream_options"),
                "body_keys": sorted(body.keys()),
                "user_field": str(body["user"])[:64] if "user" in body else None,
                "metadata_keys": sorted(body["metadata"].keys()) if isinstance(body.get("metadata"), dict) else None,
                "message_count": len(body.get("messages") or []),
                "tool_count": len(body.get("tools") or []),
            })
        return shape

    def send_json(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def start_chunked(self, content_type):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        self.wfile.flush()

    def chunk(self, data):
        if isinstance(data, str):
            data = data.encode()
        try:
            self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            raise Disconnected()

    def end_chunked(self):
        try:
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            raise Disconnected()

    def client_gone(self):
        """True when the client has closed its side of the connection."""
        try:
            readable, _, _ = select.select([self.connection], [], [], 0)
            return bool(readable) and self.connection.recv(1, socket.MSG_PEEK) == b""
        except OSError:
            return True

    def hold(self, keepalive, stream, headers_sent):
        """Wait ARGS.hold seconds. Returns the seconds waited."""
        start = time.monotonic()
        n = 0
        while time.monotonic() - start < ARGS.hold:
            time.sleep(max(0.0, min(ARGS.interval, ARGS.hold - (time.monotonic() - start))))
            if self.client_gone():
                raise Disconnected()
            if keepalive and headers_sent:
                n += 1
                self.chunk(": lmsy-keepalive %d\n\n" % n if stream else b" ")
        return time.monotonic() - start

    # ------------------------------------------------------------ routes

    def do_GET(self):
        log(self.request_shape(None))
        if self.path.rstrip("/") in ("/v1/models", "/models"):
            self.send_json(200, {"object": "list", "data": [
                {"id": m, "object": "model", "created": 0, "owned_by": "lmsy-hold-test"} for m in MODELS]})
        elif self.path == "/health":
            self.send_json(200, {"status": "ok"})
        else:
            self.send_json(404, {"error": {"message": "not found: %s" % self.path}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            body = None
        log(self.request_shape(body))

        path = self.path.rstrip("/")
        if path not in ("/v1/chat/completions", "/v1/completions") or not isinstance(body, dict):
            self.send_json(404, {"error": {"message": "not supported by the hold test: %s" % self.path}})
            return

        model = body.get("model") or "lmsy-instant"
        stream = bool(body.get("stream"))
        chat = path.endswith("chat/completions")
        keepalive = model == "lmsy-hold-keepalive"
        holds = model in ("lmsy-hold-keepalive", "lmsy-hold-silent")
        include_usage = bool((body.get("stream_options") or {}).get("include_usage"))

        started = time.monotonic()
        outcome = "completed"
        sse = "text/event-stream; charset=utf-8"
        try:
            # Keepalive sends headers at once; silent sends nothing until ready.
            headers_sent = False
            if keepalive:
                self.start_chunked(sse if stream else "application/json")
                headers_sent = True
            waited = self.hold(keepalive, stream, headers_sent) if holds else 0.0
            text = "LM-Switchyard hold test: %s answered after %.0f seconds." % (model, waited)
            if stream:
                if not headers_sent:
                    self.start_chunked(sse)
                self.stream_answer(model, text, chat, include_usage)
                self.end_chunked()
            else:
                obj = self.full_answer(model, text, chat)
                if headers_sent:
                    self.chunk(json.dumps(obj))
                    self.end_chunked()
                else:
                    self.send_json(200, obj)
        except Disconnected:
            outcome = "client_disconnected"
        log({"event": "result", "path": self.path, "model": model, "stream": stream,
             "outcome": outcome, "seconds": round(time.monotonic() - started, 1)})

    # ------------------------------------------------------------ bodies

    def full_answer(self, model, text, chat):
        usage = {"prompt_tokens": 10, "completion_tokens": 12, "total_tokens": 22}
        if chat:
            return {"id": "chatcmpl-" + uuid.uuid4().hex, "object": "chat.completion",
                    "created": int(time.time()), "model": model,
                    "choices": [{"index": 0, "finish_reason": "stop",
                                 "message": {"role": "assistant", "content": text}}],
                    "usage": usage}
        return {"id": "cmpl-" + uuid.uuid4().hex, "object": "text_completion",
                "created": int(time.time()), "model": model,
                "choices": [{"index": 0, "finish_reason": "stop", "text": text}],
                "usage": usage}

    def stream_answer(self, model, text, chat, include_usage):
        cid = ("chatcmpl-" if chat else "cmpl-") + uuid.uuid4().hex
        created = int(time.time())
        obj = "chat.completion.chunk" if chat else "text_completion"

        def event(choices, usage=None):
            payload = {"id": cid, "object": obj, "created": created, "model": model, "choices": choices}
            if usage is not None:
                payload["usage"] = usage
            self.chunk("data: %s\n\n" % json.dumps(payload))

        if chat:
            event([{"index": 0, "delta": {"role": "assistant", "content": ""}, "finish_reason": None}])
        for word in text.split(" "):
            piece = word + " "
            if chat:
                event([{"index": 0, "delta": {"content": piece}, "finish_reason": None}])
            else:
                event([{"index": 0, "text": piece, "finish_reason": None}])
            time.sleep(0.02)
        if chat:
            event([{"index": 0, "delta": {}, "finish_reason": "stop"}])
        else:
            event([{"index": 0, "text": "", "finish_reason": "stop"}])
        if include_usage:
            event([], {"prompt_tokens": 10, "completion_tokens": 12, "total_tokens": 22})
        self.chunk("data: [DONE]\n\n")


def main():
    global ARGS
    p = argparse.ArgumentParser(description="LM-Switchyard hold-test server")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=18100)
    p.add_argument("--hold", type=float, default=90, help="seconds to hold each request (default 90)")
    p.add_argument("--interval", type=float, default=5, help="seconds between keepalives (default 5)")
    p.add_argument("--log", default="hold-test.log", help="JSON-lines log file (default hold-test.log)")
    ARGS = p.parse_args()
    server = ThreadingHTTPServer((ARGS.host, ARGS.port), Handler)
    print("hold-test server on http://%s:%d/v1  hold=%ss  models: %s"
          % (ARGS.host, ARGS.port, ARGS.hold, ", ".join(MODELS)), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
