import http.client
import json
import os
from pathlib import Path
import queue
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest


class WindowsRemoteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.fixture = Path(cls.directory.name).resolve() / "session.jsonl"
        records = [
            {"type": "user", "message": {"content": "fixture question"}},
            {"type": "assistant", "message": {"model": "claude-fixture-model", "content": [{"type": "text", "text": "fixture answer"}]}},
            {"type": "assistant", "message": {"model": "<synthetic>", "content": []}},
            {"type": "user", "message": {"model": "not-an-assistant-model", "content": "follow-up"}},
        ]
        cls.fixture.write_text("".join(json.dumps(record) + "\n" for record in records), encoding="utf-8")
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            cls.port = listener.getsockname()[1]
        script = os.environ.get("TOKI_TEST_REMOTE", str(Path(__file__).with_name("toki_windows_remote.py")))
        cls.process = subprocess.Popen([os.environ.get("TOKI_TEST_PYTHON", sys.executable), "-u", script, "--bind", "127.0.0.1", "--port", str(cls.port), "--access", "loopback", "--agent-snapshot-stdin", "--no-qr"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", env={**os.environ, "PYTHONIOENCODING": "cp1252"})
        cls.addClassCleanup(cls.cleanup)
        cls.output = queue.Queue()
        threading.Thread(target=lambda: [cls.output.put(line) for line in cls.process.stdout], daemon=True).start()
        cls.link_token = None
        cls.code = None
        deadline = time.monotonic() + 15
        while (not cls.link_token or not cls.code) and time.monotonic() < deadline:
            try:
                line = cls.output.get(timeout=1)
            except queue.Empty:
                if cls.process.poll() is not None:
                    raise RuntimeError("Companion exited during startup")
                continue
            if "?token=" in line:
                cls.link_token = line.strip().split("?token=", 1)[1]
            if line.startswith("pairing_code="):
                cls.code = line.strip().split("=", 1)[1]
        if not cls.code or not cls.link_token:
            raise RuntimeError("Companion did not become ready")

    @classmethod
    def cleanup(cls):
        if cls.process.poll() is None:
            cls.process.stdin.close()
            try:
                cls.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                cls.process.kill()
                cls.process.wait(timeout=5)
        for pipe in (cls.process.stdout, cls.process.stderr):
            pipe.close()
        cls.directory.cleanup()

    @classmethod
    def request(cls, method, path, body=None, token=None, origin=None):
        conn = http.client.HTTPConnection("127.0.0.1", cls.port, timeout=5)
        headers = {"Origin": origin or f"http://127.0.0.1:{cls.port}"}
        if token:
            headers["Authorization"] = "Bearer " + token
        if body is not None:
            headers["Content-Type"] = "application/json"
        conn.request(method, path, json.dumps(body) if body is not None else None, headers)
        response = conn.getresponse()
        data = response.read()
        result = json.loads(data) if "json" in response.getheader("Content-Type", "") else data.decode()
        status = response.status
        conn.close()
        return status, result

    @classmethod
    def publish(cls, payload):
        cls.process.stdin.write(json.dumps(payload) + "\n")
        cls.process.stdin.flush()

    def pair(self):
        status, data = self.request("POST", "/api/pair?token=" + self.link_token, {"code": self.code})
        self.assertEqual(200, status)
        return data["token"]

    def await_agents(self, token, count):
        for _ in range(50):
            status, data = self.request("GET", "/api/agents", token=token)
            self.assertEqual(200, status)
            if len(data) == count:
                return data
            time.sleep(0.02)
        self.fail("Snapshot did not reach HTTP endpoint")

    def test_01_pairing_and_static_ui(self):
        self.assertEqual(200, self.request("GET", "/")[0])
        self.assertEqual(403, self.request("GET", "/api/usage")[0])
        self.assertEqual(403, self.request("POST", "/api/pair?token=wrong", {"code": self.code})[0])
        self.assertEqual(403, self.request("POST", "/api/pair?token=" + self.link_token, {"code": "wrong"})[0])
        self.assertEqual(403, self.request("POST", "/api/pair?token=" + self.link_token, {"code": self.code}, origin="https://example.com")[0])
        self.pair()

    def test_02_usage_and_transcripts(self):
        token = self.pair()
        self.publish({"usage": [{"id": "claude-code", "name": "Claude Code", "remaining": .75, "windows": [{"label": "5h", "left": 75}]}]})
        self.publish({"agents": [{"pid": 123, "provider": "claude", "title": "Fixture", "session": str(self.fixture), "process": False}]})
        agents = self.await_agents(token, 1)
        self.assertFalse(agents[0]["writable"])
        self.assertFalse(agents[0]["screen"])
        self.assertFalse(agents[0]["uploads"])
        self.assertIsNone(agents[0]["attention"])
        self.assertTrue(agents[0]["title"].startswith("Recent:"))
        self.assertEqual("claude-fixture-model", agents[0]["model"])
        status, data = self.request("GET", "/api/transcript?pid=123", token=token)
        self.assertEqual(200, status)
        self.assertTrue(any(e.get("text") == "fixture answer" for e in data["entries"]))
        status, data = self.request("GET", "/api/usage", token=token)
        self.assertEqual(75, data["accounts"][0]["windows"][0]["left"])
        for path in ("/api/send", "/api/upload", "/api/reset", "/api/open"):
            self.assertEqual(403, self.request("POST", path, {"pid": 123, "text": "test"}, token)[0])
        self.assertEqual(403, self.request("GET", "/api/screen?pid=123", token=token)[0])
        self.publish({"agents": []})
        self.await_agents(token, 0)
        self.assertEqual([], self.request("GET", "/api/transcript?pid=123", token=token)[1]["entries"])

    def test_025_codex_transcript(self):
        token = self.pair()
        codex = self.fixture.parent / "codex.jsonl"
        codex.write_text(json.dumps({"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "Codex fixture answer"}]}}) + "\n", encoding="utf-8")
        self.publish({"agents": [{"pid": 124, "provider": "codex", "session": str(codex)}]})
        self.await_agents(token, 1)
        for _ in range(50):
            status, data = self.request("GET", "/api/transcript?pid=124", token=token)
            if data.get("entries"):
                break
            time.sleep(.02)
        self.assertEqual(200, status)
        self.assertTrue(any(e.get("text") == "Codex fixture answer" for e in data["entries"]))
        self.publish({"agents": []})
        self.await_agents(token, 0)

    def test_03_unsafe_and_oversized_files_rejected(self):
        token = self.pair()
        huge = self.fixture.parent / "large.jsonl"
        with huge.open("wb") as file:
            file.truncate(16 * 1024 * 1024 + 1)
        self.publish({"agents": [{"pid": 123, "provider": "claude", "session": str(self.fixture)}]})
        self.await_agents(token, 1)
        self.publish({"agents": [{"pid": 999, "provider": "claude", "session": str(huge)}, {"pid": 998, "provider": "claude", "session": "relative.jsonl"}]})
        self.await_agents(token, 0)

    def test_04_revoke(self):
        token = self.pair()
        deadline = time.monotonic() + 5
        device = None
        while time.monotonic() < deadline:
            try:
                line = self.output.get(timeout=1)
            except queue.Empty:
                continue
            if line.startswith("devices="):
                devices = json.loads(line[8:])["devices"]
                if devices:
                    device = devices[-1]["id"]
        self.assertIsNotNone(device)
        # Revoke every paired device to avoid depending on equal-second sort order.
        for item in devices:
            self.publish({"revoke": item["id"]})
        for _ in range(50):
            status, _ = self.request("GET", "/api/usage", token=token)
            if status == 403:
                break
            time.sleep(.02)
        self.assertEqual(403, status)

    def test_99_parent_exit_stops_server(self):
        self.process.stdin.close()
        self.assertEqual(0, self.process.wait(timeout=5))


if __name__ == "__main__":
    unittest.main()
