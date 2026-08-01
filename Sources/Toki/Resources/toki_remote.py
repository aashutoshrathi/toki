#!/usr/bin/env python3
"""
toki-remote — prototype companion server for Toki.

Remote-control experience for agents that don't support remote control.
Run this on your Mac, scan the QR code with your phone (same LAN or
Tailscale tailnet), and you get:

  - live list of running Claude Code and Codex agents
  - real chat titles (Claude's customTitle/aiTitle, else first message)
  - live transcript with markdown rendering
  - "waiting on you" detection (pending tool call with no result)
  - reply from the phone: taps are injected into the agent's terminal
    via tmux send-keys, iTerm2 AppleScript (by tty, no focus stealing),
    or Terminal.app + System Events as fallback.

Zero dependencies — Python 3.9+ stdlib only.

Usage:
    python3 toki_remote.py [--port 8765]

If the phone can't connect over plain Wi-Fi:
  - macOS firewall may be blocking python3: System Settings → Network →
    Firewall → Options → allow python3 (macOS prompts on first run;
    if you dismissed it, it stays blocked).
  - Guest Wi-Fi networks often isolate clients from each other
    ("AP isolation") — Tailscale side-steps all of this, use that URL.

SECURITY: injecting keystrokes into a terminal is arbitrary command
execution. A random link token plus a separately displayed verification
code are required to create a time-limited session. Only run this on
networks you trust (your tailnet qualifies; a coffee-shop LAN does not).
"""

import argparse
import json
import os
import re
import secrets
import sqlite3
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HOME = os.path.expanduser("~")
QUIET_PERIOD = 10.0  # seconds; same reasoning as Toki's attentionQuietPeriod
# Gap between delivering the message text and the submitting Enter. Sent together, a TUI like
# Claude Code reads the trailing carriage return as part of the paste and inserts a newline
# instead of submitting; a short pause makes the Enter register as its own keypress.
SUBMIT_DELAY = 0.15
AUTO_ACCEPTED_EDITS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
CANONICAL_AGENTS = None
CANONICAL_AGENTS_LOCK = threading.Lock()

# ============================================================ QR (byte mode,
# EC level L, versions 1-10, mask 0; verified against cv2.QRCodeDetector)

_QR_BLOCKS = {
    1: ([19], 7), 2: ([34], 10), 3: ([55], 15), 4: ([80], 20), 5: ([108], 26),
    6: ([68, 68], 18), 7: ([78, 78], 20), 8: ([97, 97], 24), 9: ([116, 116], 30),
    10: ([68, 68, 69, 69], 18),
}
_QR_CAP = {1: 17, 2: 32, 3: 53, 4: 78, 5: 106, 6: 134, 7: 154, 8: 192, 9: 230, 10: 271}
_QR_ALIGN = {1: [], 2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30], 6: [6, 34],
             7: [6, 22, 38], 8: [6, 24, 42], 9: [6, 26, 46], 10: [6, 28, 50]}

_EXP = [0] * 512
_LOG = [0] * 256
_x = 1
for _i in range(255):
    _EXP[_i] = _x
    _LOG[_x] = _i
    _x <<= 1
    if _x & 0x100:
        _x ^= 0x11D
for _i in range(255, 512):
    _EXP[_i] = _EXP[_i - 255]


def _rs_ecc(data, n):
    gen = [1]
    for i in range(n):
        nxt = [0] * (len(gen) + 1)
        for j, g in enumerate(gen):
            nxt[j] ^= g
            nxt[j + 1] ^= _EXP[(_LOG[g] + i) % 255] if g else 0
        gen = nxt
    rem = list(data) + [0] * n
    for i in range(len(data)):
        factor = rem[i]
        if factor:
            for j in range(1, len(gen)):
                rem[i + j] ^= _EXP[(_LOG[gen[j]] + _LOG[factor]) % 255] if gen[j] else 0
    return rem[len(data):]


def qr_matrix(text):
    data = text.encode("utf-8")
    version = next((v for v in range(1, 11) if _QR_CAP[v] >= len(data)), None)
    if version is None:
        raise ValueError("payload too long for QR v10-L")
    block_lens, ec_len = _QR_BLOCKS[version]
    total_data = sum(block_lens)

    bits = []
    def put(value, length):
        for i in range(length - 1, -1, -1):
            bits.append((value >> i) & 1)
    put(0b0100, 4)
    put(len(data), 16 if version >= 10 else 8)
    for b in data:
        put(b, 8)
    put(0, min(4, total_data * 8 - len(bits)))
    while len(bits) % 8:
        bits.append(0)
    codewords = [int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits), 8)]
    for i in range(total_data - len(codewords)):
        codewords.append((0xEC, 0x11)[i % 2])

    blocks, pos = [], 0
    for length in block_lens:
        blocks.append(codewords[pos:pos + length])
        pos += length
    eccs = [_rs_ecc(b, ec_len) for b in blocks]
    final = []
    for i in range(max(block_lens)):
        for b in blocks:
            if i < len(b):
                final.append(b[i])
    for i in range(ec_len):
        for e in eccs:
            final.append(e[i])
    data_bits = []
    for cw in final:
        for i in range(7, -1, -1):
            data_bits.append((cw >> i) & 1)

    size = 17 + 4 * version
    m = [[0] * size for _ in range(size)]
    func = [[False] * size for _ in range(size)]

    def set_func(r, c, val):
        m[r][c] = val
        func[r][c] = True

    def finder(r, c):
        for dr in range(-4, 5):
            for dc in range(-4, 5):
                rr, cc = r + dr, c + dc
                if 0 <= rr < size and 0 <= cc < size:
                    dist = max(abs(dr), abs(dc))
                    set_func(rr, cc, 1 if dist != 2 and dist != 4 else 0)

    finder(3, 3)
    finder(3, size - 4)
    finder(size - 4, 3)
    for i in range(size):
        if not func[6][i]:
            set_func(6, i, (i + 1) % 2)
        if not func[i][6]:
            set_func(i, 6, (i + 1) % 2)
    centers = _QR_ALIGN[version]
    lo, hi = (centers[0], centers[-1]) if centers else (0, 0)
    for r in centers:
        for c in centers:
            if (r, c) in ((lo, lo), (lo, hi), (hi, lo)):
                continue  # the three finder corners carry no alignment pattern
            for dr in range(-2, 3):
                for dc in range(-2, 3):
                    set_func(r + dr, c + dc, 1 if max(abs(dr), abs(dc)) != 1 else 0)
    for i in range(9):
        if not func[8][i]:
            set_func(8, i, 0)
        if not func[i][8]:
            set_func(i, 8, 0)
    for i in range(8):
        set_func(size - 1 - i, 8, 0)
        set_func(8, size - 1 - i, 0)
    if version >= 7:
        for i in range(18):
            a, b = size - 11 + i % 3, i // 3
            set_func(a, b, 0)
            set_func(b, a, 0)

    idx = 0
    right = size - 1
    while right >= 1:
        if right == 6:
            right -= 1
        for vert in range(size):
            for j in range(2):
                c = right - j
                upward = ((right + 1) & 2) == 0
                r = size - 1 - vert if upward else vert
                if not func[r][c] and idx < len(data_bits):
                    bit = data_bits[idx]
                    idx += 1
                    if (r + c) % 2 == 0:  # mask 0
                        bit ^= 1
                    m[r][c] = bit
        right -= 2

    fmt_data = (0b01 << 3) | 0  # EC L, mask 0
    rem = fmt_data
    for _ in range(10):
        rem = (rem << 1) ^ ((rem >> 9) * 0x537)
    fmt = ((fmt_data << 10) | rem) ^ 0x5412
    def fbit(i):
        return (fmt >> i) & 1
    for i in range(6):
        m[i][8] = fbit(i)
    m[7][8] = fbit(6)
    m[8][8] = fbit(7)
    m[8][7] = fbit(8)
    for i in range(9, 15):
        m[8][14 - i] = fbit(i)
    for i in range(8):
        m[8][size - 1 - i] = fbit(i)
    for i in range(8, 15):
        m[size - 15 + i][8] = fbit(i)
    m[size - 8][8] = 1  # dark module

    if version >= 7:
        rem = version
        for _ in range(12):
            rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
        vbits = (version << 12) | rem
        for i in range(18):
            bit = (vbits >> i) & 1
            a, b = size - 11 + i % 3, i // 3
            m[a][b] = bit
            m[b][a] = bit
    return m


def qr_terminal(text):
    """ANSI half-block rendering with explicit colors, so it scans on any theme."""
    matrix = qr_matrix(text)
    quiet, size = 2, len(matrix)
    width = size + 2 * quiet

    def module(r, c):
        rr, cc = r - quiet, c - quiet
        return matrix[rr][cc] if 0 <= rr < size and 0 <= cc < size else 0

    lines = []
    for r in range(0, width, 2):
        row = []
        for c in range(width):
            fg = 16 if module(r, c) else 231
            bg = 16 if module(r + 1, c) else 231
            row.append(f"\x1b[38;5;{fg}m\x1b[48;5;{bg}m▀")
        lines.append("".join(row) + "\x1b[0m")
    return "\n".join(lines)


# ================================================================= discovery

def shell(cmd, timeout=5):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return out.stdout if out.returncode == 0 else None
    except Exception:
        return None


def provider_of(command):
    parts = command.split()
    if not parts:
        return None
    exe = os.path.basename(parts[0]).lower()
    entry = parts[1].lower() if len(parts) > 1 else ""
    if exe == "claude":
        return "claude"
    if exe == "codex" or exe.startswith("codex-") or (exe in ("node", "bun") and "/@openai/codex/" in entry):
        return "codex"
    if exe == "opencode":
        return "opencode"
    return None


def discover_agents():
    out = shell(["/bin/ps", "-axo", "pid=,ppid=,tty=,etime=,command="])
    if not out:
        return []
    rows = []
    for line in out.splitlines():
        parts = line.split(None, 4)
        if len(parts) != 5:
            continue
        pid, ppid, tty, etime, command = parts
        provider = provider_of(command)
        if not provider:
            continue
        rows.append({
            "pid": int(pid), "ppid": int(ppid), "provider": provider,
            "tty": None if tty in ("??", "?", "-") else tty,
            "etime": etime, "command": command,
        })
    with CANONICAL_AGENTS_LOCK:
        canonical = None if CANONICAL_AGENTS is None else list(CANONICAL_AGENTS)
    if canonical is not None:
        return agents_from_snapshot(rows, canonical)

    pids = {r["pid"] for r in rows}
    roots = [r for r in rows if r["ppid"] not in pids]
    for r in roots:
        r["cwd"] = cwd_of_pid(r["pid"])
        if r["provider"] == "claude":
            r["session"] = newest_claude_session(r["command"], r["cwd"])
        elif r["provider"] == "codex":
            r["session"] = newest_codex_session(r["command"], r["cwd"])
        else:
            r["session"] = newest_opencode_session(r["command"], r["cwd"])
    return dedupe_agents(roots)


def agents_from_snapshot(processes, snapshot):
    """Enrich only the agents Toki's canonical scanner says are active."""
    by_pid = {process["pid"]: process for process in processes}
    result = []
    for item in snapshot:
        process = by_pid.get(item.get("pid"))
        if not process:
            continue
        agent = dict(process)
        agent["provider"] = item.get("provider") or agent["provider"]
        agent["cwd"] = item.get("cwd")
        agent["tty"] = item.get("tty")
        agent["title"] = item.get("title")
        # Prefer the session Toki already resolved with the process start time; only fall back to
        # resolving by cwd (which can't tell co-located agents apart) when it wasn't provided.
        provided = item.get("session")
        if provided:
            agent["session"] = provided
        elif agent["provider"] == "claude":
            agent["session"] = newest_claude_session(agent["command"], agent["cwd"])
        elif agent["provider"] == "codex":
            agent["session"] = newest_codex_session(agent["command"], agent["cwd"])
        else:
            agent["session"] = newest_opencode_session(agent["command"], agent["cwd"])
        result.append(agent)
    return result


def read_agent_snapshots():
    global CANONICAL_AGENTS
    for line in sys.stdin:
        try:
            payload = json.loads(line)
            agents = payload.get("agents")
            if not isinstance(agents, list):
                continue
        except (ValueError, AttributeError):
            continue
        with CANONICAL_AGENTS_LOCK:
            CANONICAL_AGENTS = agents


def dedupe_agents(agents):
    """Show a transcript once when several processes resolve to the same session."""
    result = []
    positions = {}
    for agent in agents:
        session = agent.get("session")
        key = (
            (agent.get("provider"), os.path.realpath(session))
            if session
            else (agent.get("provider"), agent.get("pid"))
        )
        previous = positions.get(key)
        if previous is None:
            positions[key] = len(result)
            result.append(agent)
        elif not result[previous].get("tty") and agent.get("tty"):
            result[previous] = agent
    return result


def cwd_of_pid(pid):
    try:  # Linux fast path; absent on macOS
        return os.readlink(f"/proc/{pid}/cwd")
    except OSError:
        pass
    out = shell(["/usr/sbin/lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"])
    if not out:
        return None
    for line in out.splitlines():
        if line.startswith("n") and len(line) > 1:
            return line[1:]
    return None


# ------------------------------------------------------------- Claude Code

def claude_project_dir(cwd):
    encoded = "-" + "-".join(p for p in cwd.split("/") if p)
    return os.path.join(HOME, ".claude", "projects", encoded)


def newest_claude_session(command, cwd):
    m = re.search(r"--resume\s+(\S+\.jsonl)", command)
    if m and os.path.exists(m.group(1)):
        return m.group(1)
    m = re.search(r"(?:--resume|--session-id|-r)\s+([a-f0-9]{8}-[a-f0-9-]+)", command)
    if m and cwd:
        p = os.path.join(claude_project_dir(cwd), m.group(1) + ".jsonl")
        if os.path.exists(p):
            return p
    if not cwd:
        return None
    d = claude_project_dir(cwd)
    try:
        files = [os.path.join(d, f) for f in os.listdir(d) if f.endswith(".jsonl")]
    except OSError:
        return None
    return max(files, key=os.path.getmtime, default=None)


_NOISE_PREFIXES = ("Caveat: The messages below", "<local-command-stdout>",
                   "<command-message>", "[Request interrupted")
_HARNESS_TAGS = (
    "INSTRUCTIONS",
    "system-reminder",
    "recommended_plugin",
    "recommended_plugins",
    "environment_context",
    "user_instructions",
    "apps_instructions",
    "plugins_instructions",
    "skills_instructions",
)
_HARNESS_BLOCK_RE = re.compile(
    r"<(" + "|".join(map(re.escape, _HARNESS_TAGS)) + r")(?:\s[^>]*)?>.*?</\1\s*>",
    flags=re.I | re.S,
)
_HARNESS_TAG_RE = re.compile(
    r"^\s*</?(?:" + "|".join(map(re.escape, _HARNESS_TAGS)) + r")(?:\s|>)",
    flags=re.I,
)
_HARNESS_HEADING_RE = re.compile(
    r"^\s*#\s+(?:AGENTS|CLAUDE)\.md\s+instructions\b",
    flags=re.I,
)
_USER_REQUEST_RE = re.compile(
    r"^#{1,3}\s+My request for Codex:\s*",
    flags=re.I | re.M,
)


def clean_user_text(text):
    """Strip harness noise from user messages; None means 'do not show'."""
    text = _HARNESS_BLOCK_RE.sub("", text).strip()
    request_marker = _USER_REQUEST_RE.search(text)
    if request_marker:
        text = text[request_marker.end():].strip()
    if not text or _HARNESS_TAG_RE.match(text) or _HARNESS_HEADING_RE.match(text):
        return None
    m = re.match(r"<command-name>(/?\S+)</command-name>", text)
    if m:
        args = re.search(r"<command-args>(.*?)</command-args>", text, re.S)
        arg_str = (" " + args.group(1).strip()) if args and args.group(1).strip() else ""
        name = m.group(1)
        return (name if name.startswith("/") else "/" + name) + arg_str
    m = re.match(r"<bash-input>(.*?)</bash-input>", text, re.S)
    if m:
        return "$ " + m.group(1).strip()
    for prefix in _NOISE_PREFIXES:
        if text.startswith(prefix):
            return None
    return text


def parse_claude_transcript(path, offset=0):
    """Incremental parse from byte offset. Returns (entries, new_offset)."""
    entries = []
    try:
        with open(path, "rb") as f:
            f.seek(offset)
            data = f.read()
    except OSError:
        return [], offset
    end = data.rfind(b"\n")
    if end == -1:
        return [], offset
    consumed = end + 1
    for raw in data[:consumed].split(b"\n"):
        if not raw.strip():
            continue
        try:
            j = json.loads(raw)
        except ValueError:
            continue
        entry_type = j.get("type")
        msg = j.get("message")
        if isinstance(msg, dict):
            content = msg.get("content")
            if entry_type == "user":
                texts = []
                if isinstance(content, str):
                    texts = [content]
                elif isinstance(content, list):
                    for block in content:
                        if block.get("type") == "text":
                            texts.append(block.get("text", ""))
                        elif block.get("type") == "tool_result":
                            entries.append({"role": "resolved", "id": block.get("tool_use_id")})
                for t in texts:
                    cleaned = clean_user_text(t)
                    if cleaned:
                        entries.append({"role": "user", "text": cleaned})
            elif entry_type == "assistant" and isinstance(content, list):
                for block in content:
                    btype = block.get("type")
                    if btype == "text" and block.get("text", "").strip():
                        entries.append({"role": "assistant", "text": block["text"]})
                    elif btype == "tool_use":
                        name = block.get("name", "?")
                        inp = block.get("input") or {}
                        entries.append({
                            "role": "tool", "tool": name, "id": block.get("id"),
                            "text": claude_tool_summary(name, inp),
                            "questions": extract_questions(name, inp),
                        })
        if "permissionMode" in j:
            entries.append({"role": "meta", "mode": j["permissionMode"]})
    return entries, offset + consumed


def claude_tool_summary(name, inp):
    for key in ("description", "command", "file_path", "pattern", "prompt", "url"):
        v = inp.get(key)
        if isinstance(v, str) and v.strip():
            return v.strip().splitlines()[0][:160]
    return ""


def extract_questions(name, inp):
    """AskUserQuestion payload: all questions, each with tappable option labels."""
    if name != "AskUserQuestion":
        return None
    questions = inp.get("questions")
    if not isinstance(questions, list) or not questions:
        return None
    out = []
    for q in questions:
        if isinstance(q, dict):
            out.append({"question": q.get("question", ""),
                        "options": [o.get("label", "") for o in q.get("options", [])
                                    if isinstance(o, dict)]})
    return out or None


def claude_attention(path):
    if not quiet_enough(path):
        return None
    entries, _ = parse_claude_transcript(path, 0)
    pending, order, mode = {}, [], None
    for e in entries:
        if e["role"] == "meta":
            mode = e.get("mode", mode)
        elif e["role"] == "tool":
            pending[e["id"]] = e
            order.append(e["id"])
        elif e["role"] == "resolved":
            pending.pop(e.get("id"), None)
    last = next((pending[i] for i in reversed(order) if i in pending), None)
    if not last:
        return None
    name = last["tool"]
    if name == "AskUserQuestion":
        qs = last.get("questions") or []
        first = qs[0] if qs else {"question": "", "options": []}
        return {"kind": "question", "prompt": first["question"], "options": first["options"],
                "questions": qs}
    if name in ("ExitPlanMode", "EnterPlanMode"):
        return {"kind": "question", "prompt": "Waiting on plan approval", "options": []}
    if mode == "auto":
        return None
    if mode == "acceptEdits" and name in AUTO_ACCEPTED_EDITS:
        return None
    return {"kind": "permission", "prompt": f"Allow {name}?", "options": []}


def quiet_enough(path):
    try:
        return time.time() - os.path.getmtime(path) >= QUIET_PERIOD
    except OSError:
        return False


# ------------------------------------------------------------------- Codex

CODEX_SESSIONS = os.path.join(HOME, ".codex", "sessions")
_codex_cwd_cache = {}  # path -> cwd (immutable per file)


def codex_recent_files(limit=80):
    files = []
    for root, _, names in os.walk(CODEX_SESSIONS):
        for n in names:
            if n.endswith(".jsonl"):
                p = os.path.join(root, n)
                try:
                    files.append((os.path.getmtime(p), p))
                except OSError:
                    pass
    files.sort(reverse=True)
    return [p for _, p in files[:limit]]


def codex_session_cwd(path):
    if path in _codex_cwd_cache:
        return _codex_cwd_cache[path]
    cwd = None
    try:
        with open(path, "r", errors="replace") as f:
            for _ in range(20):
                line = f.readline()
                if not line:
                    break
                try:
                    j = json.loads(line)
                except ValueError:
                    continue
                payload = j.get("payload") or {}
                if j.get("type") in ("session_meta", "turn_context") and payload.get("cwd"):
                    cwd = payload["cwd"]
                    break
    except OSError:
        pass
    _codex_cwd_cache[path] = cwd
    return cwd


def newest_codex_session(command, cwd):
    m = re.search(r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})", command)
    candidates = codex_recent_files()
    if m:
        for p in candidates:
            if m.group(1) in os.path.basename(p):
                return p
    if cwd:
        for p in candidates:
            if codex_session_cwd(p) == cwd:
                return p
    return candidates[0] if candidates else None


def codex_call_summary(payload):
    name = payload.get("name") or payload.get("type", "tool")
    args = payload.get("arguments")
    if payload.get("type") == "local_shell_call":
        cmd = (payload.get("action") or {}).get("command")
        if isinstance(cmd, list):
            return "shell", " ".join(map(str, cmd))[:160]
    if isinstance(args, str):
        try:
            parsed = json.loads(args)
        except ValueError:
            parsed = None
        if isinstance(parsed, dict):
            cmd = parsed.get("command")
            if isinstance(cmd, list):
                return name, " ".join(map(str, cmd))[:160]
            if isinstance(cmd, str):
                return name, cmd[:160]
        return name, args[:160]
    return name, ""


def parse_codex_transcript(path, offset=0):
    entries = []
    try:
        with open(path, "rb") as f:
            f.seek(offset)
            data = f.read()
    except OSError:
        return [], offset
    end = data.rfind(b"\n")
    if end == -1:
        return [], offset
    consumed = end + 1
    for raw in data[:consumed].split(b"\n"):
        if not raw.strip():
            continue
        try:
            j = json.loads(raw)
        except ValueError:
            continue
        jtype = j.get("type")
        payload = j.get("payload") or {}
        if jtype == "turn_context" and payload.get("approval_policy"):
            entries.append({"role": "meta", "mode": payload["approval_policy"]})
        elif jtype == "response_item":
            ptype = payload.get("type")
            if ptype == "message":
                role = payload.get("role")
                for block in payload.get("content") or []:
                    text = (block.get("text") or "").strip() if isinstance(block, dict) else ""
                    if not text:
                        continue
                    if role == "user":
                        cleaned = clean_user_text(text)
                        if cleaned:
                            entries.append({"role": "user", "text": cleaned})
                    elif role == "assistant":
                        entries.append({"role": "assistant", "text": text})
            elif ptype in ("function_call", "local_shell_call", "custom_tool_call"):
                name, summary = codex_call_summary(payload)
                entries.append({"role": "tool", "tool": name,
                                "id": payload.get("call_id") or payload.get("id"),
                                "text": summary, "questions": None})
            elif ptype in ("function_call_output", "custom_tool_call_output"):
                entries.append({"role": "resolved", "id": payload.get("call_id")})
    return entries, offset + consumed


def codex_attention(path):
    if not quiet_enough(path):
        return None
    entries, _ = parse_codex_transcript(path, 0)
    pending, order, policy = {}, [], None
    for e in entries:
        if e["role"] == "meta":
            policy = e.get("mode", policy)
        elif e["role"] == "tool":
            pending[e["id"]] = e
            order.append(e["id"])
        elif e["role"] == "resolved":
            pending.pop(e.get("id"), None)
    last = next((pending[i] for i in reversed(order) if i in pending), None)
    if not last or policy == "never":
        return None
    label = last["text"] or last["tool"]
    return {"kind": "permission", "prompt": f"Approve: {label}?", "options": []}


# ------------------------------------------------------------------- titles

_title_cache = {}  # path -> (mtime, title)


OPENCODE_DB = os.path.join(
    os.environ.get("OPENCODE_DATA_DIR") or os.path.join(HOME, ".local", "share", "opencode"),
    "opencode.db",
)


def opencode_query(sql, params=()):
    if not os.path.exists(OPENCODE_DB):
        return []
    try:
        con = sqlite3.connect(f"file:{OPENCODE_DB}?mode=ro", uri=True, timeout=1)
        try:
            return con.execute(sql, params).fetchall()
        finally:
            con.close()
    except sqlite3.Error:
        return []


def newest_opencode_session(command, cwd):
    if not cwd:
        return None
    rows = opencode_query("SELECT id FROM session WHERE directory=? ORDER BY time_updated DESC LIMIT 1", (cwd,))
    return rows[0][0] if rows else None


def opencode_session_ts(session_id):
    rows = opencode_query("SELECT time_updated FROM session WHERE id=?", (session_id,))
    return rows[0][0] / 1000 if rows and rows[0][0] else 0.0


def opencode_title(session_id):
    rows = opencode_query("SELECT title FROM session WHERE id=?", (session_id,))
    return rows[0][0] if rows and rows[0][0] else None


def opencode_attention(session_id):
    rows = opencode_query(
        "SELECT json_extract(data,'$.tool'), time_updated FROM part "
        "WHERE session_id=? AND json_extract(data,'$.state.status')='running' "
        "ORDER BY time_updated DESC LIMIT 1",
        (session_id,),
    )
    if not rows:
        return None
    tool, ts = rows[0]
    if not ts or time.time() - ts / 1000 < QUIET_PERIOD:
        return None
    return {"kind": "permission", "prompt": f"Allow {tool}?" if tool else "OpenCode is waiting on you", "options": []}


def opencode_tool_summary(tool, inp):
    if not isinstance(inp, dict):
        return ""
    for key in ("filePath", "path", "command", "pattern", "query", "description"):
        value = inp.get(key)
        if value:
            return str(value).replace("\n", " ")[:120]
    return ""


def opencode_entries(session_id):
    rows = opencode_query(
        "SELECT json_extract(m.data,'$.role'), p.data FROM part p "
        "JOIN message m ON p.message_id = m.id "
        "WHERE p.session_id=? ORDER BY m.time_created, p.time_created, p.id",
        (session_id,),
    )
    entries = []
    for role, pdata in rows:
        try:
            data = json.loads(pdata)
        except (ValueError, TypeError):
            continue
        kind = data.get("type")
        if kind == "text":
            if data.get("synthetic"):
                continue
            text = (data.get("text") or "").strip()
            if text:
                entries.append({"role": "assistant" if role == "assistant" else "user", "text": text})
        elif kind == "tool":
            state = data.get("state") or {}
            entries.append({
                "role": "tool",
                "tool": data.get("tool", "tool"),
                "text": opencode_tool_summary(data.get("tool"), state.get("input") or {}),
            })
    return entries


def agent_recency(agent):
    session = agent.get("session")
    if not session:
        return 0.0
    if agent["provider"] == "opencode":
        return opencode_session_ts(session)
    return os.path.getmtime(session) if os.path.exists(session) else 0.0


def chat_title(provider, path, cwd):
    fallback = os.path.basename(cwd) if cwd else provider
    if provider == "opencode":
        raw_title = opencode_title(path) if path else None
        return (clean_user_text(raw_title) if raw_title else None) or fallback
    if not path:
        return fallback
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        return fallback
    cached = _title_cache.get(path)
    if cached and cached[0] == mtime:
        return cached[1] or fallback
    title = None
    if provider == "claude":
        # /rename (customTitle) wins over the inferred aiTitle; last of each is current.
        try:
            with open(path, "r", errors="replace") as f:
                contents = f.read()
        except OSError:
            contents = ""
        custom = re.findall(r'"customTitle"\s*:\s*"([^"]+)"', contents)
        ai = re.findall(r'"aiTitle"\s*:\s*"([^"]+)"', contents)
        candidates = list(reversed(custom)) + list(reversed(ai))
        for candidate in candidates:
            title = clean_user_text(candidate)
            if title:
                break
    if not title:
        parse = parse_claude_transcript if provider == "claude" else parse_codex_transcript
        entries, _ = parse(path, 0)
        first = next((e["text"] for e in entries if e["role"] == "user"), None)
        if first:
            first = " ".join(first.split())
            title = first[:44] + "…" if len(first) > 45 else first
    _title_cache[path] = (mtime, title)
    if len(_title_cache) > 128:
        _title_cache.pop(next(iter(_title_cache)))
    return title or fallback


# ------------------------------------------------------------ key injection

SYS_EVENTS_KEYCODES = {"enter": 36, "esc": 53, "up": 126, "down": 125, "tab": 48}
TMUX_KEYS = {"enter": "Enter", "esc": "Escape", "up": "Up", "down": "Down", "tab": "Tab"}


def tmux_pane_for_tty(tty):
    dev = tty if tty.startswith("/dev/") else f"/dev/{tty}"
    for tmux in ("/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"):
        if not os.path.exists(tmux):
            continue
        out = shell([tmux, "list-panes", "-a", "-F", "#{pane_tty}\t#{pane_id}"])
        if not out:
            continue
        for line in out.splitlines():
            cols = line.split("\t")
            if len(cols) == 2 and cols[0] == dev:
                return tmux, cols[1]
    return None, None


def osascript(source):
    return shell(["/usr/bin/osascript", "-e", source], timeout=6) is not None


def safe_tty(tty):
    return bool(re.fullmatch(r"(/dev/)?[a-zA-Z0-9]+", tty or ""))


def agent_is_writable(agent):
    return safe_tty(agent.get("tty"))


def applescript_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def iterm_write(tty, payload_expr):
    dev = tty if tty.startswith("/dev/") else f"/dev/{tty}"
    return osascript(f'''
        if application id "com.googlecode.iterm2" is running then
          tell application id "com.googlecode.iterm2"
            repeat with w in windows
              repeat with t in tabs of w
                repeat with s in sessions of t
                  if tty of s is "{dev}" then
                    tell s to write text {payload_expr} newline NO
                    return
                  end if
                end repeat
              end repeat
            end repeat
          end tell
        end if
        error "tty not found"''')


def focus_terminal_tab(tty):
    dev = tty if tty.startswith("/dev/") else f"/dev/{tty}"
    return osascript(f'''
        if application id "com.apple.Terminal" is running then
          tell application id "com.apple.Terminal"
            repeat with w in windows
              repeat with t in tabs of w
                if tty of t is "{dev}" then
                  set selected of t to true
                  set index of w to 1
                  activate
                  return
                end if
              end repeat
            end repeat
          end tell
        end if
        error "tty not found"''')


def send_input(tty, text=None, key=None, raw=False):
    """Deliver input to the agent's terminal. Returns (ok, how)."""
    if not safe_tty(tty):
        return False, "unsafe tty"
    tmux, pane = tmux_pane_for_tty(tty)
    if pane:
        if key:
            ok = shell([tmux, "send-keys", "-t", pane, TMUX_KEYS[key]]) is not None
        else:
            ok = shell([tmux, "send-keys", "-t", pane, "-l", text]) is not None
            if not raw:
                time.sleep(SUBMIT_DELAY)
                ok = ok and shell([tmux, "send-keys", "-t", pane, "Enter"]) is not None
        return ok, "tmux"
    if key:
        seq = {"enter": '(character id 13)', "esc": '(character id 27)',
               "up": '((character id 27) & "[A")', "down": '((character id 27) & "[B")',
               "tab": '(character id 9)'}[key]
        if iterm_write(tty, seq):
            return True, "iterm"
    else:
        if iterm_write(tty, applescript_str(text)):
            if not raw:
                time.sleep(SUBMIT_DELAY)
                iterm_write(tty, "(character id 13)")
            return True, "iterm"
    if focus_terminal_tab(tty):
        time.sleep(0.3)
        if key:
            ok = osascript(f'tell application "System Events" to key code {SYS_EVENTS_KEYCODES[key]}')
        else:
            ok = osascript(f'tell application "System Events" to keystroke {applescript_str(text)}')
            if not raw:
                time.sleep(SUBMIT_DELAY)
                ok = ok and osascript('tell application "System Events" to key code 36')
        return ok, "terminal+system-events"
    return False, "no route to tty (not tmux/iTerm/Terminal?)"


# ------------------------------------------------------------------- server

def new_pairing_code():
    return f"{secrets.randbelow(1_000_000):06d}"


TOKEN = secrets.token_urlsafe(24)
PAIRING_CODE = new_pairing_code()
PAIRING_CODE_TTL = 2 * 60
HOSTED_ORIGIN = "https://rc.toki.aashutosh.dev"
SESSION_TTL = 12 * 60 * 60
SESSION_TTL_CHOICES = (60 * 60, 12 * 60 * 60, 24 * 60 * 60, 2 * 24 * 60 * 60)
PAIRING_WINDOW = 60
PAIRING_MAX_FAILURES = 5
MAX_BODY_BYTES = 256 * 1024
CSP = (
    "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
    "img-src 'self' data:; connect-src 'self'; worker-src 'self'; manifest-src 'self'; "
    "base-uri 'none'; form-action 'self'; object-src 'none'; frame-ancestors 'none'"
)
SESSIONS = {}
PAIRING_FAILURES = {}
AUTH_LOCK = threading.Lock()

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
WEBUI_DIR = os.path.join(_SCRIPT_DIR, "webui")
if not os.path.isdir(WEBUI_DIR):
    # `swift run` flattens SwiftPM's processed resources beside the script rather than into a
    # webui/ subdirectory, so serve them from the script's own directory in that case.
    WEBUI_DIR = _SCRIPT_DIR


def rotate_pairing_code():
    global PAIRING_CODE
    while True:
        time.sleep(PAIRING_CODE_TTL)
        with AUTH_LOCK:
            PAIRING_CODE = new_pairing_code()
            code = PAIRING_CODE
        print(f"pairing_code={code}", flush=True)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _cors(self):
        if self.headers.get("Origin") == HOSTED_ORIGIN:
            self.send_header("Access-Control-Allow-Origin", HOSTED_ORIGIN)
            self.send_header("Vary", "Origin")

    def _secure(self, document=False):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        if document:
            self.send_header("Content-Security-Policy", CSP)
            self.send_header("X-Frame-Options", "DENY")

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length > MAX_BODY_BYTES:
            return None
        return self.rfile.read(length)

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self._secure()
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def _authed(self, q):
        candidate = q.get("token", [""])[0]
        now = time.time()
        with AUTH_LOCK:
            expired = [token for token, expiry in SESSIONS.items() if expiry <= now]
            for token in expired:
                del SESSIONS[token]
            return candidate in SESSIONS

    def _pair(self, q):
        link_token = q.get("token", [""])[0]
        if not secrets.compare_digest(link_token, TOKEN):
            return self._json({"error": "bad link token"}, 403)

        raw = self._read_body()
        if raw is None:
            return self._json({"error": "request too large"}, 413)
        try:
            body = json.loads(raw)
        except ValueError:
            return self._json({"error": "bad json"}, 400)
        code = str(body.get("code", "")).replace(" ", "")
        client = self.client_address[0]
        now = time.time()

        with AUTH_LOCK:
            recent = [
                attempt for attempt in PAIRING_FAILURES.get(client, [])
                if attempt > now - PAIRING_WINDOW
            ]
            if len(recent) >= PAIRING_MAX_FAILURES:
                PAIRING_FAILURES[client] = recent
                return self._json({"error": "too many attempts; try again shortly"}, 429)
            if not secrets.compare_digest(code, PAIRING_CODE):
                recent.append(now)
                PAIRING_FAILURES[client] = recent
                return self._json({"error": "incorrect verification code"}, 403)

            PAIRING_FAILURES.pop(client, None)
            session_token = secrets.token_urlsafe(32)
            SESSIONS[session_token] = now + SESSION_TTL

        return self._json({"token": session_token, "expiresIn": SESSION_TTL})

    def _static(self, name, ctype):
        try:
            with open(os.path.join(WEBUI_DIR, name), "rb") as f:
                body = f.read()
        except OSError:
            return self._json({"error": "not found"}, 404)
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self._secure(document=True)
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        url = urlparse(self.path)
        requested_method = self.headers.get("Access-Control-Request-Method")
        if (
            not url.path.startswith("/api/")
            or self.headers.get("Origin") != HOSTED_ORIGIN
            or requested_method not in ("GET", "POST")
        ):
            return self._json({"error": "cross-origin request not allowed"}, 403)

        self.send_response(204)
        self._cors()
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Max-Age", "600")
        self.end_headers()

    def do_GET(self):
        url = urlparse(self.path)
        q = parse_qs(url.query)
        if url.path in ("/", "/index.html"):
            return self._static("index.html", "text/html; charset=utf-8")
        if url.path == "/app.js":
            return self._static("app.js", "application/javascript; charset=utf-8")
        if url.path == "/markdown.js":
            return self._static("markdown.js", "application/javascript; charset=utf-8")
        if url.path == "/favicon.svg":
            return self._static("favicon.svg", "image/svg+xml")
        if url.path == "/styles.css":
            return self._static("styles.css", "text/css; charset=utf-8")
        if url.path == "/manifest.webmanifest":
            return self._static("manifest.webmanifest", "application/manifest+json")
        if url.path == "/sw.js":
            return self._static("sw.js", "application/javascript; charset=utf-8")
        if url.path == "/jsqr.js":
            return self._static("jsqr.js", "application/javascript; charset=utf-8")
        if url.path in ("/icon-192.png", "/icon-512.png", "/apple-touch-icon.png"):
            return self._static(url.path.lstrip("/"), "image/png")
        if not self._authed(q):
            return self._json({"error": "bad token"}, 403)
        if url.path == "/api/agents":
            result = []
            agents = discover_agents()
            agents.sort(key=agent_recency, reverse=True)
            for a in agents:
                att = None
                if a["session"]:
                    if a["provider"] == "claude":
                        att = claude_attention(a["session"])
                    elif a["provider"] == "codex":
                        att = codex_attention(a["session"])
                    else:
                        att = opencode_attention(a["session"])
                result.append({
                    "pid": a["pid"], "tty": a["tty"], "cwd": a["cwd"],
                    "provider": a["provider"],
                    "title": a.get("title") or chat_title(a["provider"], a["session"], a["cwd"]),
                    "attention": att,
                    "writable": agent_is_writable(a),
                })
            self._json(result)
        elif url.path == "/api/transcript":
            pid = int(q.get("pid", ["0"])[0])
            offset = int(q.get("offset", ["0"])[0])
            agent = next((a for a in discover_agents() if a["pid"] == pid), None)
            if not agent or not agent["session"]:
                return self._json({"entries": [], "offset": offset})
            if agent["provider"] == "opencode":
                entries = opencode_entries(agent["session"])
                if offset > len(entries):  # session changed under us
                    return self._json({"entries": [], "offset": 0, "reset": True})
                shown = entries[offset:]
                if offset == 0:
                    shown = [e for e in shown if e["role"] in ("user", "assistant", "tool")][-60:]
                return self._json({"entries": shown, "offset": len(entries)})
            try:
                size = os.path.getsize(agent["session"])
            except OSError:
                size = 0
            if offset > size:  # session file rotated/replaced
                return self._json({"entries": [], "offset": 0, "reset": True})
            parse = parse_claude_transcript if agent["provider"] == "claude" else parse_codex_transcript
            entries, new_offset = parse(agent["session"], offset)
            if offset == 0:
                shown = [e for e in entries if e["role"] in ("user", "assistant", "tool")]
                entries = shown[-60:]
            self._json({"entries": entries, "offset": new_offset})
        else:
            self._json({"error": "not found"}, 404)

    def do_POST(self):
        url = urlparse(self.path)
        q = parse_qs(url.query)
        if url.path == "/api/pair":
            return self._pair(q)
        if not self._authed(q):
            return self._json({"error": "bad token"}, 403)
        if url.path != "/api/send":
            return self._json({"error": "not found"}, 404)
        raw = self._read_body()
        if raw is None:
            return self._json({"error": "request too large"}, 413)
        try:
            body = json.loads(raw)
        except ValueError:
            return self._json({"error": "bad json"}, 400)
        agent = next((a for a in discover_agents() if a["pid"] == body.get("pid")), None)
        if not agent:
            return self._json({"error": "agent gone"}, 410)
        if not agent_is_writable(agent):
            return self._json({"error": "This non-terminal session is read-only."}, 422)
        key = body.get("key")
        text = body.get("text")
        if key not in (None, "enter", "esc", "up", "down", "tab"):
            return self._json({"error": "unknown key"}, 400)
        if not key and not (isinstance(text, str) and text):
            return self._json({"error": "nothing to send"}, 400)
        raw = bool(body.get("raw")) and text is not None and len(text) == 1
        ok, how = send_input(agent["tty"], text=text, key=key, raw=raw)
        self._json({"ok": ok, "how": how}, 200 if ok else 502)


# --------------------------------------------------------------------- main

def local_ipv4s():
    """All usable IPv4 addresses, Tailscale (100.64/10) first."""
    out = None
    for cmd in (["/sbin/ifconfig"], ["/usr/sbin/ifconfig"], ["ifconfig"], ["ip", "-4", "addr"]):
        out = shell(cmd)
        if out:
            break
    if not out:
        return []
    ips = re.findall(r"inet (\d+\.\d+\.\d+\.\d+)", out)
    ips = [ip for ip in ips if not ip.startswith("127.")]
    def is_tailscale(ip):
        a, b = int(ip.split(".")[0]), int(ip.split(".")[1])
        return a == 100 and 64 <= b <= 127
    return sorted(set(ips), key=lambda ip: (not is_tailscale(ip), ip))


def main():
    global CANONICAL_AGENTS, SESSION_TTL
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--session-ttl", type=int, choices=SESSION_TTL_CHOICES, default=SESSION_TTL)
    ap.add_argument("--agent-snapshot-stdin", action="store_true")
    ap.add_argument("--no-qr", action="store_true")
    args = ap.parse_args()
    SESSION_TTL = args.session_ttl
    if args.agent_snapshot_stdin:
        CANONICAL_AGENTS = []
        threading.Thread(target=read_agent_snapshots, daemon=True).start()
    server = ThreadingHTTPServer((args.bind, args.port), Handler)

    ips = local_ipv4s()
    print("toki-remote prototype\n")
    urls = [f"http://{ip}:{args.port}/?token={TOKEN}" for ip in ips]
    for u in urls:
        print("   " + u)
    print(f"   http://localhost:{args.port}/?token={TOKEN}\n")
    print(f"pairing_code={PAIRING_CODE}")
    threading.Thread(target=rotate_pairing_code, daemon=True).start()
    if urls and not args.no_qr:
        print("Scan with your phone (uses the first address above):\n")
        print(qr_terminal(urls[0]))
        print()
    print("If the phone can't connect: allow python3 in System Settings → Network")
    print("→ Firewall → Options, make sure both devices share the Wi-Fi/tailnet,")
    print("and prefer the Tailscale (100.x) address when you have one. Ctrl-C stops.")
    server.serve_forever()


if __name__ == "__main__":
    main()
