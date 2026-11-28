"""Read-only Windows adapter for the shared Toki companion protocol."""
import os
from pathlib import Path
import socket
import sys
import time
from urllib.parse import parse_qs, urlparse

if not (Path(__file__).parent / "toki_remote.py").exists():
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Sources/Toki/Resources"))
import toki_remote as remote


def safe_session(path):
    if not isinstance(path, str) or not os.path.isabs(path) or not path.lower().endswith(".jsonl"):
        return False
    try:
        candidate = Path(path)
        for part in (candidate, *candidate.parents):
            if part.is_symlink() or (hasattr(part, "is_junction") and part.is_junction()):
                return False
        return candidate.is_file() and 0 < candidate.stat().st_size <= 16 * 1024 * 1024
    except OSError:
        return False


def discover_sessions():
    with remote.CANONICAL_AGENTS_LOCK:
        if time.time() - remote.CANONICAL_AGENTS_AT > remote.CANONICAL_MAX_AGE:
            return []
        snapshot = list(remote.CANONICAL_AGENTS or [])[:32]
    result = []
    for item in snapshot:
        if not isinstance(item, dict) or item.get("provider") not in ("claude", "codex"):
            continue
        if not isinstance(item.get("pid"), int) or not safe_session(item.get("session")):
            continue
        result.append({**item, "tty": None, "host": "windows-history", "cwd": None,
                       "title": "Recent: " + str(item.get("title") or "Conversation")[:100],
                       "ppid": 0, "command": "", "t3": None})
    return result


class ReadOnlyHandler(remote.Handler):
    def do_POST(self):
        if urlparse(self.path).path == "/api/pair":
            return super().do_POST()
        if not self._gate():
            return
        if not self._authed(parse_qs(urlparse(self.path).query)):
            return self._json({"error": "bad token"}, 403)
        return self._json({"error": "Windows preview provides read-only access."}, 403)

    def do_GET(self):
        if urlparse(self.path).path == "/api/screen":
            if not self._gate():
                return
            return self._json({"error": "Terminal control is not available in this preview."}, 403)
        try:
            return super().do_GET()
        except (ValueError, TypeError, AttributeError, OSError):
            return self._json({"error": "Session data could not be read."}, 422)

    def _json(self, data, status=200):
        if urlparse(self.path).path == "/api/agents" and isinstance(data, list):
            for item in data:
                item.update(writable=False, screen=False, uploads=False, attention=None, history=True)
        return super()._json(data, status)


def main():
    for stream in (sys.stdin, sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8")
    original_read = remote.read_control_messages

    def read_until_parent_exits():
        original_read()
        os._exit(0)

    remote.Handler = ReadOnlyHandler
    remote.discover_agents = discover_sessions
    remote.agent_is_writable = lambda agent: False
    remote.claude_attention = lambda path: None
    remote.codex_attention = lambda path: None
    remote.machine_name = lambda: socket.gethostname()
    remote.local_ipv4s = lambda: []
    remote.read_control_messages = read_until_parent_exits
    remote.main()


if __name__ == "__main__":
    main()
