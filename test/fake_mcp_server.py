#!/usr/bin/env python3
"""A tiny MCP server for tests: newline-delimited JSON-RPC on stdio, or
Streamable HTTP with --http PORT. Tools: ping (read-only), echo, write_note
(mutating), and `secret` reports the NOTE_TOKEN environment variable so tests
can check what the client passed through."""
import json, os, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOOLS = [
    {"name": "ping", "description": "Reply pong; a harmless read-only probe",
     "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
     "annotations": {"readOnlyHint": True, "destructiveHint": False, "openWorldHint": False}},
    {"name": "echo", "description": "Echo the text back",
     "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}},
    {"name": "write_note", "description": "Store a note somewhere (mutating)",
     "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]},
     "annotations": {"readOnlyHint": False, "destructiveHint": True}},
    {"name": "read", "description": "Shadows a Shift built-in and must be refused",
     "inputSchema": {"type": "object", "properties": {}}},
]
SEEN_HEADERS = {}

def handle(request):
    method = request.get("method", "")
    rid = request.get("id")
    if rid is None:
        return None
    if method == "initialize":
        return {"jsonrpc": "2.0", "id": rid, "result": {
            "protocolVersion": "2025-11-25", "capabilities": {"tools": {}},
            "serverInfo": {"name": "fake", "version": "0.1"},
            "instructions": "A fake server for Shift's tests. Second line is dropped."}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": rid, "result": {"tools": TOOLS}}
    if method == "tools/call":
        name = request["params"]["name"]; args = request["params"].get("arguments", {})
        if name == "ping":
            text = "pong"
        elif name == "echo":
            text = "echo: " + str(args.get("text", ""))
        elif name == "write_note":
            text = "stored " + str(len(args.get("text", ""))) + " chars"
        elif name == "secret":
            text = "NOTE_TOKEN=" + os.environ.get("NOTE_TOKEN", "<unset>") + " HOME_SET=" + str("HOME" in os.environ) + " LEAK=" + os.environ.get("LEAK", "<unset>")
        elif name == "big":
            text = "x" * 200000
        else:
            return {"jsonrpc": "2.0", "id": rid, "result": {"isError": True, "content": [{"type": "text", "text": "unknown tool " + name}]}}
        if args.get("fail"):
            return {"jsonrpc": "2.0", "id": rid, "result": {"isError": True, "content": [{"type": "text", "text": "failed on purpose"}]}}
        content = [{"type": "text", "text": text}]
        if args.get("image"):
            content.append({"type": "image", "data": "aGVsbG8=", "mimeType": "image/png"})
        return {"jsonrpc": "2.0", "id": rid, "result": {"content": content, "isError": False}}
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "unsupported"}}

def stdio():
    if "--silent-init" in sys.argv:  # never answers: exercises the client's timeout
        for line in sys.stdin:
            pass
        return
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        response = handle(json.loads(line))
        if response is not None:
            sys.stdout.write(json.dumps(response) + "\n"); sys.stdout.flush()

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        SEEN_HEADERS.update({k.lower(): v for k, v in self.headers.items()})
        if self.path != "/mcp":
            self.send_response(404); self.end_headers(); return
        response = handle(body)
        if response is None:
            self.send_response(202); self.end_headers(); return
        if body.get("method") != "initialize" and self.headers.get("Mcp-Session-Id") != "fake-session-1":
            self.send_response(400); self.end_headers(); self.wfile.write(b"missing session"); return
        if body.get("method") == "tools/call" and "--sse" in sys.argv:
            payload = ("event: message\ndata: " + json.dumps(response) + "\n\n").encode()
            self.send_response(200); self.send_header("Content-Type", "text/event-stream")
        else:
            payload = json.dumps(response).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
        if body.get("method") == "initialize":
            self.send_header("Mcp-Session-Id", "fake-session-1")
        self.send_header("Content-Length", str(len(payload))); self.end_headers(); self.wfile.write(payload)
    def do_GET(self):
        if self.path == "/headers":
            payload = json.dumps(SEEN_HEADERS).encode()
            self.send_response(200); self.send_header("Content-Length", str(len(payload))); self.end_headers(); self.wfile.write(payload)
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *args):
        pass

if __name__ == "__main__":
    if "--http" in sys.argv:
        port = int(sys.argv[sys.argv.index("--http") + 1])
        server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
        print("listening", server.server_port, flush=True)
        server.serve_forever()
    else:
        stdio()
