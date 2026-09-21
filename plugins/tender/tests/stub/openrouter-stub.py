#!/usr/bin/env python3
"""Fake OpenRouter chat-completions endpoint for tender's offline tests.

Behaviour is chosen by the requested model's suffix:
  stub/ok       bullets that include the model name
  stub/fenced   a ```ts fenced snippet (tests fence stripping)
  stub/empty    empty content
  stub/fenceonly a fence with nothing inside (strips to nothing)
  stub/blank    whitespace-only content
  stub/error    OpenRouter-style error envelope, HTTP 400
  stub/garbage  non-JSON body
  stub/slow     sleeps 5 s before answering
  stub/slowok   sleeps 2 s, then answers ok (long enough to inspect curl's argv)
  stub/badcost  ok response with a non-numeric usage.cost ("n/a")
  stub/nousage  ok response without a usage block
Every request body is written to $STUB_LAST_REQUEST and the request's
Authorization header to $STUB_LAST_AUTH, for assertions.
Usage: openrouter-stub.py [port]   (default 48123)
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LAST = os.environ.get("STUB_LAST_REQUEST", "/tmp/tender-stub-last-request.json")
LAST_AUTH = os.environ.get("STUB_LAST_AUTH", "/tmp/tender-stub-last-auth.txt")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self._send(200, b'{"ok":true}')

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        with open(LAST, "wb") as fh:
            fh.write(raw)
        with open(LAST_AUTH, "w") as fh:
            fh.write(self.headers.get("Authorization") or "")
        try:
            body = json.loads(raw)
        except Exception:
            body = {}
        model = str(body.get("model", ""))
        mode = model.split("/")[-1]
        user = next((m.get("content", "") for m in body.get("messages", []) if m.get("role") == "user"), "")
        usage = {
            "prompt_tokens": max(1, len(user) // 4),
            "completion_tokens": 12,
            "total_tokens": max(1, len(user) // 4) + 12,
            "cost": 0.0042,
            "prompt_tokens_details": {"cached_tokens": 3},
        }
        if mode == "slow":
            time.sleep(5)
        if mode == "slowok":
            time.sleep(2)
        if mode == "garbage":
            return self._send(200, b"<html>not json</html>")
        if mode == "error":
            return self._json(400, {"error": {"message": "stub failure", "code": 400}})
        if mode == "badcost":
            usage["cost"] = "n/a"
        content = {
            "ok": "- STUB ANSWER\n  - model: %s" % model,
            "fenced": "```ts\nexport const generated = 1;\n```",
            "empty": "",
            "fenceonly": "```ts\n```",
            "blank": "   \n",
            "badcost": "- STUB ANSWER\n  - model: %s" % model,
            "nousage": "- STUB ANSWER\n  - model: %s" % model,
        }.get(mode, "- STUB ANSWER")
        resp = {
            "id": "stub",
            "model": model,
            "choices": [{"message": {"role": "assistant", "content": content}}],
        }
        if mode != "nousage":
            resp["usage"] = usage
        self._json(200, resp)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj).encode())

    def _send(self, code, data):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 48123
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
