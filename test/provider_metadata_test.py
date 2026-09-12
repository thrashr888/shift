"""Metadata-only loopback HTTP tests; never launch inference or read settings."""

import json
import os
from pathlib import Path
import subprocess
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


ROOT = Path(__file__).resolve().parents[1]


class ProviderMetadataHTTPTests(unittest.TestCase):
    def setUp(self):
        self.requests = []
        self.body = {"models": [{"name": "fixture:latest",
                                 "context_length": 16384,
                                 "size_vram": 2147483648,
                                 "size": 777777777}]}
        self.delay = 0
        self.status = 200
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                owner.requests.append(self.path)
                time.sleep(owner.delay)
                body = (owner.body if isinstance(owner.body, bytes)
                        else json.dumps(owner.body).encode())
                self.send_response(owner.status)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def metadata(self, model="fixture", provider="ollama", twice=False):
        call = f'(provider-metadata! \'{provider} {json.dumps(model)} {json.dumps(self.base)} #f)'
        script = f"""
          (use-modules (live-agent provider-metadata) (live-agent json))
          {"(begin " + call + ")" if twice else ""}
          (display (json-write {call}))
        """
        result = subprocess.run(
            ["guile", "-L", "src", "-L", "extensions", "-C", "build", "-c", script],
            cwd=ROOT, env={**os.environ, "GUILE_AUTO_COMPILE": "0"},
            capture_output=True, text=True, timeout=4, check=True)
        return json.loads(result.stdout)

    def test_metadata_get_only_and_cached(self):
        value = self.metadata(twice=True)
        self.assertEqual(self.requests, ["/api/ps"])
        self.assertEqual(value["context_limit"], 16384)
        self.assertEqual(value["memory_bytes"], 2147483648)
        self.assertEqual(value["memory_label"], "GPU/model allocated")

    def test_missing_fields_never_use_size(self):
        self.body = {"models": [{"name": "fixture:latest", "size": 777777777}]}
        value = self.metadata()
        self.assertIsNone(value["context_limit"])
        self.assertIsNone(value["memory_bytes"])
        self.assertEqual(value["context_reason"], "loaded-context-unavailable")

    def test_slow_metadata_times_out_and_failure_is_cached(self):
        self.delay = 2
        started = time.monotonic()
        value = self.metadata(twice=True)
        self.assertLess(time.monotonic() - started, 1.8)
        self.assertEqual(value["reason"], "metadata-unreachable")
        self.assertEqual(self.requests, ["/api/ps"])

    def test_unsupported_endpoint_does_not_retry(self):
        self.status = 404
        self.assertEqual(self.metadata(twice=True)["reason"], "metadata-unreachable")
        self.assertEqual(self.requests, ["/api/ps"])

    def test_malformed_response_is_unavailable(self):
        self.body = b"not-json"
        self.assertEqual(self.metadata()["reason"], "metadata-invalid")

    def test_oversized_response_is_bounded(self):
        self.body = b" " * 70000
        self.assertIsNone(self.metadata()["context_limit"])
        self.assertEqual(self.requests, ["/api/ps"])

    def test_demo_and_unsupported_provider_never_connect(self):
        self.assertEqual(self.metadata(model="demo")["reason"], "demo-no-metadata")
        self.assertEqual(self.metadata(provider="openai")["reason"],
                         "provider-metadata-unsupported")
        self.assertEqual(self.requests, [])


if __name__ == "__main__":
    unittest.main()
