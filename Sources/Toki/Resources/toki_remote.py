#!/usr/bin/env python3
"""Dependency-free companion server for Toki Remote Control.

SECURITY: terminal keystroke injection is arbitrary command execution. Sessions require both a
random link token and a separately displayed verification code and are time-limited. Only use this
server on a trusted network.
"""

import argparse
import base64
import binascii
import ipaddress
import json
import os
import re
import secrets
import socketserver
import sqlite3
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HOME = os.path.expanduser("~")
QUIET_PERIOD = 10.0  # seconds; same reasoning as Toki's attentionQuietPeriod
# TUIs can treat an Enter sent with pasted text as part of the paste rather than a submit key.
SUBMIT_DELAY = 0.15
# Picker navigation needs time to repaint between synthetic keystrokes.
SEQ_KEY_DELAY = 0.12
MAX_SEQ_KEYS = 200
NAMED_KEYS = ("enter", "esc", "up", "down", "tab")
AUTO_ACCEPTED_EDITS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
CANONICAL_AGENTS = None
CANONICAL_AGENTS_AT = 0.0
CANONICAL_AGENTS_LOCK = threading.Lock()
USAGE_SNAPSHOT = []
USAGE_SNAPSHOT_AT = 0.0
USAGE_LOCK = threading.Lock()
# Toki publishes every 15s; after this, live discovery is safer than a stale canonical snapshot.
CANONICAL_MAX_AGE = 90.0

# Byte-mode QR, EC level L, versions 1–10, mask 0; verified with cv2.QRCodeDetector.

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
    if exe == "fx":
        return "fx"
    if exe == "agy":
        return "antigravity"
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
        fresh = time.time() - CANONICAL_AGENTS_AT <= CANONICAL_MAX_AGE
        canonical = list(CANONICAL_AGENTS) if CANONICAL_AGENTS is not None and fresh else None
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
        elif r["provider"] == "opencode":
            r["session"] = newest_opencode_session(r["command"], r["cwd"])
        elif r["provider"] == "fx":
            r["session"] = newest_fx_session(r["cwd"])
        elif r["provider"] == "antigravity":
            r["session"] = newest_agy_session(r["cwd"])
        else:
            r["session"] = None
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
        # Toki's start-time match distinguishes co-located agents; cwd fallback cannot.
        provided = item.get("session")
        if provided:
            agent["session"] = provided
        elif agent["provider"] == "claude":
            agent["session"] = newest_claude_session(agent["command"], agent["cwd"])
        elif agent["provider"] == "codex":
            agent["session"] = newest_codex_session(agent["command"], agent["cwd"])
        elif agent["provider"] == "opencode":
            agent["session"] = newest_opencode_session(agent["command"], agent["cwd"])
        elif agent["provider"] == "fx":
            agent["session"] = newest_fx_session(agent["cwd"])
        elif agent["provider"] == "antigravity":
            agent["session"] = newest_agy_session(agent["cwd"])
        else:
            agent["session"] = None
        result.append(agent)
    return result


def read_control_messages():
    """Toki's side of the pipe: agent snapshots to display, and revocations to act on."""
    global CANONICAL_AGENTS, CANONICAL_AGENTS_AT, USAGE_SNAPSHOT, USAGE_SNAPSHOT_AT
    for line in sys.stdin:
        try:
            payload = json.loads(line)
        except ValueError:
            continue
        if not isinstance(payload, dict):
            continue
        revoke = payload.get("revoke")
        if isinstance(revoke, str) and revoke:
            if revoke_device(revoke):
                publish_devices()
            continue
        usage = payload.get("usage")
        if isinstance(usage, list):
            with USAGE_LOCK:
                USAGE_SNAPSHOT = usage
                USAGE_SNAPSHOT_AT = time.time()
            continue
        agents = payload.get("agents")
        if not isinstance(agents, list):
            continue
        with CANONICAL_AGENTS_LOCK:
            CANONICAL_AGENTS = agents
            CANONICAL_AGENTS_AT = time.time()


def current_usage():
    """The last usage Toki published, and whether it is old enough to distrust."""
    with USAGE_LOCK:
        accounts = list(USAGE_SNAPSHOT)
        published = USAGE_SNAPSHOT_AT
    if not published:
        return {"accounts": [], "stale": False, "waiting": True}
    return {
        "accounts": accounts,
        "stale": time.time() - published > CANONICAL_MAX_AGE,
        "waiting": False,
    }


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
                            # Tool output is unbounded; the UI only needs completion state.
                            entries.append({
                                "role": "resolved",
                                "id": block.get("tool_use_id"),
                                "ts": j.get("timestamp"),
                                "failed": bool(block.get("is_error")),
                            })
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
                            "detail": claude_tool_detail(name, inp),
                            "ts": j.get("timestamp"),
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


_TOOL_DETAIL_KEYS = {
    "Bash": ("command",),
    "Read": ("file_path", "offset", "limit"),
    "Edit": ("file_path",),
    "Write": ("file_path",),
    "NotebookEdit": ("notebook_path",),
    "Grep": ("pattern", "path", "glob"),
    "Glob": ("pattern", "path"),
    "WebFetch": ("url",),
    "WebSearch": ("query",),
    "Task": ("subagent_type",),
}


def claude_tool_detail(name, inp):
    if not isinstance(inp, dict):
        return ""
    summary = claude_tool_summary(name, inp)
    parts = []
    for key in _TOOL_DETAIL_KEYS.get(name, ()):
        value = inp.get(key)
        if value in (None, "", []):
            continue
        text = " ".join(str(value).split())
        if text and text != summary:
            parts.append(text)
    return " · ".join(parts)[:240]


def normalize_questions(questions, multi_key):
    """A picker payload as the phone needs it: every question, its header, whether it takes more
    than one answer, and each option's label and description.

    Claude's AskUserQuestion and OpenCode's `question` tool carry the same shape under different
    names -- Claude marks a multi-select with `multiSelect`, OpenCode with `multiple` -- so both
    reach here with the key that means "more than one" for that provider.
    """
    if not isinstance(questions, list) or not questions:
        return None
    out = []
    for q in questions:
        if not isinstance(q, dict):
            continue
        options = []
        for o in q.get("options", []):
            if isinstance(o, dict) and o.get("label"):
                options.append({"label": o.get("label", ""),
                                "description": o.get("description", "") or ""})
            elif isinstance(o, str) and o:
                options.append({"label": o, "description": ""})
        out.append({"question": q.get("question", ""),
                    "header": q.get("header", "") or "",
                    "multi": bool(q.get(multi_key)),
                    "options": options})
    return out or None


def extract_questions(name, inp):
    """AskUserQuestion payload: all questions, each with tappable options."""
    if name != "AskUserQuestion":
        return None
    return normalize_questions(inp.get("questions"), "multiSelect")


def question_attention(qs):
    """An attention payload for a picker. The phone renders every question from `questions`; the
    top-level `prompt`/`options` stay populated from the first for the notification text and any
    client that predates multi-question support."""
    if not qs:
        return {"kind": "question", "prompt": "Agent is waiting on you", "options": [], "questions": []}
    first = qs[0]
    return {"kind": "question", "prompt": first.get("question", ""),
            "options": [o["label"] for o in first.get("options", [])],
            "questions": qs}


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
        return question_attention(qs)
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


def newest_fx_session(cwd):
    if not cwd:
        return None
    base = os.path.expanduser("~/.fx/sessions")
    try:
        index = json.load(open(os.path.join(base, "index.json")))
    except Exception:
        return None
    best, best_ts = None, -1
    for s in index.get("sessions", []):
        if s.get("workspace_root") != cwd:
            continue
        ts = s.get("updated_at_ms") or 0
        if ts > best_ts:
            best_ts, best = ts, s.get("id")
    if not best:
        return None
    path = os.path.join(base, best, "events.jsonl")
    return path if os.path.exists(path) else None


def newest_agy_session(cwd):
    if not cwd:
        return None
    base = os.path.expanduser("~/.gemini/antigravity-cli")
    latest = {}
    try:
        for line in open(os.path.join(base, "history.jsonl")):
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("workspace") != cwd:
                continue
            cid, ts = e.get("conversationId"), e.get("timestamp", 0)
            if cid and ts > latest.get(cid, 0):
                latest[cid] = ts
    except OSError:
        return None
    if not latest:
        return None
    cid = max(latest, key=latest.get)
    for name in ("transcript_full.jsonl", "transcript.jsonl"):
        path = os.path.join(base, "brain", cid, ".system_generated", "logs", name)
        if os.path.exists(path):
            return path
    return None


def jsonl_lines(path, offset):
    try:
        with open(path, "rb") as f:
            f.seek(offset)
            data = f.read()
    except OSError:
        return None, offset
    end = data.rfind(b"\n")
    if end == -1:
        return None, offset
    consumed = end + 1
    out = []
    for raw in data[:consumed].split(b"\n"):
        if not raw.strip():
            continue
        try:
            out.append(json.loads(raw))
        except ValueError:
            continue
    return out, offset + consumed


def parse_fx_transcript(path, offset=0):
    records, new_offset = jsonl_lines(path, offset)
    if records is None:
        return [], offset
    entries = []
    for j in records:
        if j.get("kind") != "history_turn_committed":
            continue
        turn = (j.get("payload") or {}).get("turn") or {}
        user = turn.get("user") or {}
        cleaned = clean_user_text(user.get("text") or "") if isinstance(user, dict) else ""
        if cleaned:
            entries.append({"role": "user", "text": cleaned})
        for step in ((turn.get("execution") or {}).get("tool_steps") or []):
            if isinstance(step, dict):
                entries.append({"role": "tool", "tool": step.get("name") or "tool",
                                "id": step.get("id"), "text": "", "questions": None})
        assistant = turn.get("assistant")
        if isinstance(assistant, str) and assistant.strip():
            entries.append({"role": "assistant", "text": assistant.strip()})
    return entries, new_offset


USER_REQUEST_RE = re.compile(r"<USER_REQUEST>\s*(.*?)\s*</USER_REQUEST>", re.S)


def parse_agy_transcript(path, offset=0):
    records, new_offset = jsonl_lines(path, offset)
    if records is None:
        return [], offset
    entries = []
    for j in records:
        jtype = j.get("type")
        if jtype == "USER_INPUT":
            content = j.get("content")
            if isinstance(content, str):
                m = USER_REQUEST_RE.search(content)
                cleaned = clean_user_text((m.group(1) if m else content).strip())
                if cleaned:
                    entries.append({"role": "user", "text": cleaned})
        elif jtype == "PLANNER_RESPONSE":
            content = j.get("content")
            if isinstance(content, str) and content.strip():
                entries.append({"role": "assistant", "text": content.strip()})
        for call in (j.get("tool_calls") or []):
            if isinstance(call, dict):
                args = call.get("args") or {}
                summary = args.get("toolAction") if isinstance(args, dict) else ""
                entries.append({"role": "tool", "tool": call.get("name") or "tool",
                                "id": call.get("id") or call.get("tool_call_id"),
                                "text": summary or "", "questions": None})
    return entries, new_offset


TRANSCRIPT_PARSERS = {
    "claude": parse_claude_transcript,
    "codex": parse_codex_transcript,
    "fx": parse_fx_transcript,
    "antigravity": parse_agy_transcript,
}


# Read-only tools (view_file, grep_search, find_by_name) run without asking, so only these leave the
# transcript resting on a proposal antigravity is blocked on.
AGY_APPROVAL_TOOLS = ("run_command",)
AGY_QUESTION_TOOL = "ask_question"
AGY_BLOCKING_TOOLS = AGY_APPROVAL_TOOLS + (AGY_QUESTION_TOOL,)


def agy_attention(path):
    """Antigravity writes the tool call it wants to run, then blocks for approval, so a pending
    permission is the final record: a model proposal (PLANNER_RESPONSE) holding a blocking call
    with nothing appended after it. Answering appends the call's result, moving the tail past the
    call and clearing this. A blocking call is either an approval-gated command or an ask_question
    picker; the latter carries the questions to show instead of an approve/reject.

    This does not fire for an auto-approved command that is merely executing. The instant such a
    command starts, Antigravity appends a "running as a background task" record (verified against a
    live session), and then more planner output, so the tail is no longer a lone call. A trailing
    blocking call therefore means the agent is waiting on the human, not running a command."""
    if not quiet_enough(path):
        return None
    records, _ = jsonl_lines(path, 0)
    last = records[-1] if records else None
    if not isinstance(last, dict) or last.get("type") != "PLANNER_RESPONSE":
        return None
    calls = last.get("tool_calls") or []
    pending = next((c for c in reversed(calls)
                    if isinstance(c, dict) and c.get("name") in AGY_BLOCKING_TOOLS), None)
    if not pending:
        return None
    args = pending.get("args") if isinstance(pending.get("args"), dict) else {}
    if pending.get("name") == AGY_QUESTION_TOOL:
        qs = normalize_questions(args.get("questions"), "is_multi_select")
        return question_attention(qs) if qs else None
    label = (args.get("toolSummary") or args.get("toolAction")
             or args.get("CommandLine") or pending.get("name"))
    return {"kind": "permission", "prompt": f"Allow: {label}?", "options": []}


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


def opencode_questions(pdata):
    """The questions a running `question` tool is waiting on, from its stored call arguments."""
    try:
        data = json.loads(pdata)
    except (ValueError, TypeError):
        return None
    inp = (data.get("state") or {}).get("input") or {}
    return normalize_questions(inp.get("questions"), "multiple")


def opencode_attention(session_id):
    rows = opencode_query(
        "SELECT json_extract(data,'$.tool'), time_updated, data FROM part "
        "WHERE session_id=? AND json_extract(data,'$.state.status')='running' "
        "ORDER BY time_updated DESC LIMIT 1",
        (session_id,),
    )
    if not rows:
        return None
    tool, ts, pdata = rows[0]
    if not ts or time.time() - ts / 1000 < QUIET_PERIOD:
        return None
    # OpenCode's picker matches Claude's question shape and can be answered from the phone.
    if tool == "question":
        qs = opencode_questions(pdata)
        if qs:
            return question_attention(qs)
    return {"kind": "permission", "prompt": f"Allow {tool}?" if tool else "OpenCode is waiting on you", "options": []}


def _claude_model(j):
    msg = j.get("message")
    return msg.get("model") if isinstance(msg, dict) else None


def _codex_model(j):
    return (j.get("payload") or {}).get("model") if j.get("type") == "turn_context" else None


def _fx_model(j):
    """fx records the model on session_started and on each usage checkpoint, both under a `model`
    key nested in the payload; walk the record for the last one so a mid-session switch is caught."""
    if j.get("kind") not in ("session_started", "usage_checkpointed"):
        return None
    found, stack = None, [j.get("payload")]
    while stack:
        o = stack.pop()
        if isinstance(o, dict):
            for k, v in o.items():
                if k == "model" and isinstance(v, str):
                    found = v
                elif isinstance(v, (dict, list)):
                    stack.append(v)
        elif isinstance(o, list):
            stack.extend(o)
    return found


AGY_MODEL_RE = re.compile(r"gemini-[0-9]+(?:\.[0-9]+)*(?:-[a-z]+)*", re.I)


def agy_model(session_path):
    """Antigravity keeps the model only inside a metadata blob in its per-conversation db, so read
    the newest gen_metadata row and pull the id out of it. Best-effort: None when it is not found."""
    parts = session_path.split(os.sep)
    try:
        cid = parts[parts.index("brain") + 1]
    except (ValueError, IndexError):
        return None
    db = os.path.join(HOME, ".gemini", "antigravity-cli", "conversations", cid + ".db")
    if not os.path.exists(db):
        return None
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=1)
        try:
            row = con.execute("SELECT data FROM gen_metadata ORDER BY idx DESC LIMIT 1").fetchone()
        finally:
            con.close()
    except sqlite3.Error:
        return None
    if not row or row[0] is None:
        return None
    blob = row[0] if isinstance(row[0], str) else row[0].decode("utf-8", "replace")
    m = AGY_MODEL_RE.search(blob)
    return m.group(0) if m else None


def opencode_model(session_id):
    rows = opencode_query("SELECT model FROM session WHERE id=?", (session_id,))
    raw = rows[0][0] if rows and rows[0][0] else None
    if not raw:
        return None
    # OpenCode stores the model as a JSON object ({"id","providerID","variant"}); show its id.
    try:
        obj = json.loads(raw)
    except (ValueError, TypeError):
        return raw
    return obj.get("id") or obj.get("model") or raw if isinstance(obj, dict) else raw


JSONL_MODEL_EXTRACTORS = {"claude": _claude_model, "codex": _codex_model, "fx": _fx_model}
# path -> (offset, model): the model as of the bytes read so far, so each poll parses only what was
# appended since the last one rather than re-reading a growing session in full.
_model_stream = {}


def jsonl_model(path, extract):
    """The current model in a jsonl session, read incrementally. The model line can sit anywhere --
    far behind the tail in a long session -- so a bounded tail scan would miss it, but re-reading the
    whole file every poll would not; this keeps the last value and consumes only the new bytes."""
    try:
        size = os.path.getsize(path)
    except OSError:
        _model_stream.pop(path, None)
        return None
    prev = _model_stream.get(path)
    # A shorter file than last time means the session was replaced; start over.
    offset, model = prev if prev and prev[0] <= size else (0, None)
    records, new_offset = jsonl_lines(path, offset)
    for j in (records or []):
        v = extract(j)
        if v:
            model = v
    _model_stream[path] = (new_offset if records is not None else offset, model)
    if len(_model_stream) > 128:
        _model_stream.pop(next(iter(_model_stream)))
    return model


def model_of(agent):
    """The model an agent is currently running, or None when it cannot be read for that provider."""
    provider, session = agent.get("provider"), agent.get("session")
    if not session:
        return None
    if provider == "antigravity":
        return agy_model(session)
    if provider == "opencode":
        return opencode_model(session)
    extract = JSONL_MODEL_EXTRACTORS.get(provider)
    return jsonl_model(session, extract) if extract else None


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
            tool = data.get("tool", "tool")
            entry = {
                "role": "tool",
                "tool": tool,
                "text": opencode_tool_summary(tool, state.get("input") or {}),
            }
            if tool == "question":
                qs = normalize_questions((state.get("input") or {}).get("questions"), "multiple")
                if qs:
                    entry["questions"] = qs
                    entry["text"] = state.get("title") or opencode_tool_summary(tool, state.get("input") or {})
            entries.append(entry)
    return entries


def agent_recency(agent):
    session = agent.get("session")
    if not session:
        return 0.0
    if agent["provider"] == "opencode":
        return opencode_session_ts(session)
    return os.path.getmtime(session) if os.path.exists(session) else 0.0


_machine_name = None


def machine_name():
    """The Mac's friendly name, so a phone paired to more than one Mac can tell their tabs apart.

    ComputerName is what the user set in System Settings; fall back to the network node name, minus
    the .local that would otherwise clutter a browser tab title. Resolved once -- it does not change
    under a running server.
    """
    global _machine_name
    if _machine_name is None:
        name = shell(["/usr/sbin/scutil", "--get", "ComputerName"])
        if not name:
            try:
                name = os.uname().nodename
            except OSError:
                name = ""
        name = (name or "").strip().splitlines()[0].strip() if name else ""
        if name.endswith(".local"):
            name = name[:-len(".local")]
        _machine_name = name or "Mac"
    return _machine_name


def display_path(cwd):
    """The agent's folder written the way you'd write it: ~/Git/toki, not /Users/you/Git/toki."""
    if not cwd:
        return ""
    home = HOME.rstrip("/")
    if not home:
        return cwd
    if cwd == home:
        return "~"
    if cwd.startswith(home + "/"):
        return "~" + cwd[len(home):]
    return cwd


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
        # The last /rename wins over the last inferred title.
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
        parse = TRANSCRIPT_PARSERS.get(provider, parse_codex_transcript)
        entries, _ = parse(path, 0)
        first = next((e["text"] for e in entries if e["role"] == "user"), None)
        if first:
            first = " ".join(first.split())
            title = first[:44] + "…" if len(first) > 45 else first
    _title_cache[path] = (mtime, title)
    if len(_title_cache) > 128:
        _title_cache.pop(next(iter(_title_cache)))
    return title or fallback


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


def initial_transcript_window(entries, limit=60):
    """The first payload: the last `limit` visible messages plus the `resolved` events that
    complete the tool calls among them. A `resolved` follows its `tool`, so keeping everything from
    the oldest shown message onward carries each call's completion; without it, a call that finished
    before the transcript opened stays `running`. `meta` is dropped."""
    visible = [i for i, e in enumerate(entries) if e["role"] in ("user", "assistant", "tool")]
    start = visible[-limit] if len(visible) > limit else 0
    return [e for e in entries[start:] if e["role"] in ("user", "assistant", "tool", "resolved")]


def transcript_id(agent):
    """Identify the transcript an offset belongs to, so a client can tell when it was replaced.

    An offset is a position inside one particular file and means nothing in another. /clear starts
    a fresh session, and the old offset then indexes into the middle of the new transcript. Size
    alone can't catch that: it only shows up as `offset > size` while the new file is still shorter
    than the old offset, and a session that outgrows it between two polls slips through.

    Device and inode name the file itself, so a swap is visible however the two compare in length.
    OpenCode's "session" is an id rather than a path, so it already identifies itself.
    """
    session = agent.get("session") if agent else None
    if not session:
        return ""
    try:
        st = os.stat(session)
    except OSError:
        return session
    return f"{st.st_dev}:{st.st_ino}"


def agent_order(agent):
    """Most recent first, but every agent you can reply to ahead of every one you can't.

    Read-only sessions (Codex desktop and friends) are only there to be watched, so a busy one
    would otherwise sit at the top of the picker -- and be selected by default -- while the agent
    actually waiting on you is further down.
    """
    return (agent_is_writable(agent), agent_recency(agent))


def applescript_str(s):
    # AppleScript string literals cannot contain raw newlines; escape backslashes first.
    return '"' + (
        s.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\r\n", "\\n")
        .replace("\n", "\\n")
        .replace("\r", "\\n")
    ) + '"'


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


def osascript_out(source):
    return shell(["/usr/bin/osascript", "-e", source], timeout=6)


def iterm_read(tty):
    dev = tty if tty.startswith("/dev/") else f"/dev/{tty}"
    return osascript_out(f'''
        if application id "com.googlecode.iterm2" is running then
          tell application id "com.googlecode.iterm2"
            repeat with w in windows
              repeat with t in tabs of w
                repeat with s in sessions of t
                  if tty of s is "{dev}" then
                    return text of s
                  end if
                end repeat
              end repeat
            end repeat
          end tell
        end if
        error "tty not found"''')


def terminal_read(tty):
    dev = tty if tty.startswith("/dev/") else f"/dev/{tty}"
    return osascript_out(f'''
        if application id "com.apple.Terminal" is running then
          tell application id "com.apple.Terminal"
            repeat with w in windows
              repeat with t in tabs of w
                if tty of t is "{dev}" then
                  return contents of t
                end if
              end repeat
            end repeat
          end tell
        end if
        error "tty not found"''')


ANSI_SGR_RE = re.compile(r"\x1b\[[0-9;]*m")


def trim_screen(text):
    """The tail of a captured screen, bounded by lines and bytes. Trailing blank lines a pane pads
    itself with are dropped so the picker sits at the bottom of the mirror. Color escape codes are
    kept for the phone to render, but ignored when judging whether a trailing line is blank."""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    lines = text.split("\n")
    while lines and not ANSI_SGR_RE.sub("", lines[-1]).strip():
        lines.pop()
    if len(lines) > MAX_SCREEN_LINES:
        lines = lines[-MAX_SCREEN_LINES:]
    out = "\n".join(lines)
    if len(out) > MAX_SCREEN_CHARS:
        # Cut on a line boundary so a kept color escape is never split mid-sequence.
        out = out[-MAX_SCREEN_CHARS:]
        nl = out.find("\n")
        out = out[nl + 1:] if nl != -1 else out
    return out


def capture_screen(tty, route=None):
    """The visible terminal text for an agent's tty, or None when no route can read it. Mirrors an
    interactive picker (e.g. /model) on the phone through the same three routes send_input writes to:
    tmux, iTerm, then Terminal. tmux and both apps report only the visible region, not scrollback.

    The tmux route keeps color escape codes (`-e`) so a picker whose selection is shown only by a
    highlight color -- OpenCode's, for one -- is legible on the phone; the app-scripted routes can
    only read plain text."""
    if not safe_tty(tty):
        return None
    tmux, pane = route if route is not None else tmux_pane_for_tty(tty)
    if pane:
        out = shell([tmux, "capture-pane", "-e", "-p", "-t", pane])
        return trim_screen(out) if out is not None else None
    for reader in (iterm_read, terminal_read):
        out = reader(tty)
        if out is not None:
            return trim_screen(out)
    return None


def send_input(tty, text=None, key=None, raw=False, route=None):
    """Deliver input to the agent's terminal. Returns (ok, how).

    `route` is an already-resolved (tmux, pane) pair; pass it to skip tmux discovery, which a
    caller delivering many keystrokes resolves once rather than paying for on every one.
    """
    if not safe_tty(tty):
        return False, "unsafe tty"
    tmux, pane = route if route is not None else tmux_pane_for_tty(tty)
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


def send_sequence(tty, items):
    """Deliver an ordered run of keystrokes -- named keys (Enter/Tab/arrows/Esc) and single
    characters typed as-is -- to answer a picker. Stops at the first failure so a half-delivered
    answer does not keep going. Returns (ok, how).

    The delivery route is resolved once for the whole run and handed to every send_input call:
    `tmux list-panes` is a subprocess, and without this a long walkthrough would rediscover the
    route on every key -- whichever route it turns out to be.
    """
    if not safe_tty(tty):
        return False, "unsafe tty"
    route = tmux_pane_for_tty(tty)
    how = "sequence"
    for i, item in enumerate(items):
        if i:
            time.sleep(SEQ_KEY_DELAY)
        if item in NAMED_KEYS:
            ok, how = send_input(tty, key=item, route=route)
        else:
            ok, how = send_input(tty, text=item, raw=True, route=route)
        if not ok:
            return False, how
    return True, how


def image_extension(data):
    """The file extension for an image's bytes, or None if they are not a known image type. The
    type is sniffed from the content, never a declared header, so only real images reach disk."""
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "png"
    if data[:3] == b"\xff\xd8\xff":
        return "jpg"
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return "gif"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "webp"
    if data[4:8] == b"ftyp" and data[8:12] in (
        b"heic", b"heix", b"heim", b"heis", b"hevc", b"hevx", b"hevm", b"hevs", b"mif1", b"msf1"
    ):
        return "heic"
    return None


def decode_image_payload(value):
    """The bytes behind an uploaded image field -- a data: URL or a bare base64 string -- or None if
    it is malformed or larger than the image cap. The encoded length is checked before decoding so
    an oversized payload is rejected without being expanded into memory."""
    if not isinstance(value, str) or not value:
        return None
    if value.startswith("data:"):
        if "," not in value:
            return None
        value = value.split(",", 1)[1]
    b64 = value
    if len(b64) > MAX_UPLOAD_BODY_BYTES:
        return None
    try:
        data = base64.b64decode(b64, validate=True)
    except (binascii.Error, ValueError):
        return None
    if not data or len(data) > MAX_IMAGE_BYTES:
        return None
    return data


def prune_uploads(now=None, reserve=0):
    """Keep the uploads folder bounded, by age and by total size. Anything past its TTL goes; then,
    if what remains plus `reserve` (the image about to be written) exceeds the aggregate cap, the
    oldest survivors are evicted until it fits. Run under UPLOAD_LOCK so it stays bounded under the
    concurrent uploads a threaded server allows."""
    now = time.time() if now is None else now
    try:
        names = os.listdir(UPLOAD_DIR)
    except OSError:
        return
    survivors = []
    for name in names:
        path = os.path.join(UPLOAD_DIR, name)
        try:
            st = os.stat(path)
        except OSError:
            continue
        if now - st.st_mtime > UPLOAD_TTL:
            try:
                os.remove(path)
            except OSError:
                pass
        else:
            survivors.append((st.st_mtime, st.st_size, path))
    total = sum(size for _, size, _ in survivors)
    for _, size, path in sorted(survivors):  # oldest first
        if total + reserve <= MAX_UPLOAD_DIR_BYTES:
            break
        try:
            os.remove(path)
            total -= size
        except OSError:
            pass


def save_upload(data):
    """Write validated image bytes to the uploads folder under a generated name and return the
    absolute path, or None if the bytes are not an image or cannot be written. The name is the
    server's own, so nothing a caller sends can escape the folder."""
    ext = image_extension(data)
    if not ext:
        return None
    path = os.path.join(UPLOAD_DIR, f"{int(time.time())}-{secrets.token_hex(6)}.{ext}")
    # Prune and write atomically so concurrent uploads cannot each pass the directory cap.
    with UPLOAD_LOCK:
        try:
            os.makedirs(UPLOAD_DIR, exist_ok=True)
            prune_uploads(reserve=len(data))
            # Create as 0600 immediately; chmod after writing would expose a readable window.
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as f:
                f.write(data)
        except OSError:
            return None
    return path


def new_pairing_code():
    return f"{secrets.randbelow(1_000_000):06d}"


def device_name(user_agent):
    """A label a person can recognise their own phone by, from the User-Agent.

    This is a convenience for telling two paired devices apart in Toki's list, not an identity: a
    client writes its own User-Agent and can claim anything. What actually distinguishes a session
    is the id minted at pairing, which the device never sees and cannot influence.
    """
    ua = user_agent or ""
    if "iPhone" in ua:
        kind = "iPhone"
    elif "iPad" in ua:
        kind = "iPad"
    elif "Android" in ua:
        kind = "Android device"
    elif "Macintosh" in ua or "Mac OS X" in ua:
        kind = "Mac"
    elif "Windows" in ua:
        kind = "Windows PC"
    elif "Linux" in ua:
        kind = "Linux device"
    else:
        kind = "Device"
    # Order matters: Chrome and Edge both claim Safari, Edge also claims Chrome.
    for token, browser in (("Edg/", "Edge"), ("CriOS", "Chrome"), ("Chrome/", "Chrome"),
                           ("FxiOS", "Firefox"), ("Firefox/", "Firefox"), ("Safari/", "Safari")):
        if token in ua:
            return f"{kind} ({browser})"
    return kind


def client_ip(peer, forwarded_for):
    """The device's address, and whether it is really a proxy standing in for one.

    `tailscale serve` and `cloudflared` both dial us from 127.0.0.1, so the peer address says
    nothing about the phone behind them. They forward the original address instead; trust that
    header only when the peer is loopback, or any caller could spoof its own address and defeat
    the rate limiting keyed on it.
    """
    try:
        direct = ipaddress.ip_address(peer)
    except ValueError:
        return peer, False
    if not direct.is_loopback:
        return peer, False
    first = (forwarded_for or "").split(",")[0].strip()
    if not first:
        return peer, True
    try:
        ipaddress.ip_address(first)
    except ValueError:
        return peer, True
    return first, False


def int_param(q, name, default=0):
    """A non-negative integer query parameter, or the default when it is missing or malformed."""
    try:
        value = int(q.get(name, [""])[0])
    except (TypeError, ValueError, IndexError):
        return default
    return value if value >= 0 else default


TOKEN = secrets.token_urlsafe(24)
PAIRING_CODE = new_pairing_code()
PAIRING_CODE_TTL = 2 * 60
HOSTED_ORIGIN = "https://rc.toki.aashutosh.dev"
SESSION_TTL = 12 * 60 * 60
SESSION_TTL_CHOICES = (60 * 60, 12 * 60 * 60, 24 * 60 * 60, 2 * 24 * 60 * 60)
PAIRING_WINDOW = 60
PAIRING_MAX_FAILURES = 5
MAX_BODY_BYTES = 256 * 1024
# Bound terminal injection independently of the general request-body cap.
MAX_SEND_CHARS = 8_000
# The mirrored picker only needs the tail of what is on screen; keep the payload small.
MAX_SCREEN_LINES = 80
MAX_SCREEN_CHARS = 8_000
# Base64 adds roughly 33%, so the upload-body cap exceeds the decoded-image cap.
MAX_IMAGE_BYTES = 12 * 1024 * 1024
MAX_UPLOAD_BODY_BYTES = 17 * 1024 * 1024
UPLOAD_DIR = os.path.join(HOME, ".toki", "remote-uploads")
UPLOAD_TTL = 24 * 60 * 60
MAX_UPLOAD_DIR_BYTES = 256 * 1024 * 1024
UPLOAD_LOCK = threading.Lock()
# Each upload buffers its body and decoded image; bound concurrent memory use.
UPLOAD_SLOTS = threading.BoundedSemaphore(2)
UPLOAD_SLOT_TIMEOUT = 30
# Pairing is cheap once the code is known, so bound session-table growth.
MAX_SESSIONS = 32
CSP = (
    "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
    # blob: is the attach preview's object URL, which Safari does not treat as 'self'.
    "img-src 'self' data: blob:; connect-src 'self'; worker-src 'self'; manifest-src 'self'; "
    "base-uri 'none'; form-action 'self'; object-src 'none'; frame-ancestors 'none'"
)
SESSIONS = {}
PAIRING_FAILURES = {}
AUTH_LOCK = threading.Lock()

# Some modes require a wildcard bind: Tailscale reaches the port directly while its proxy and
# Cloudflare dial over loopback. Enforce reachability per request. "loopback" forbids relayed
# clients; "tunnel" explicitly permits Cloudflare's relay.
ACCESS_POLICIES = ("loopback", "tunnel", "tailnet", "private", "any")
ACCESS_POLICY = "private"
# Custom-mode Host values; standard local, IP, Tailscale and Cloudflare hosts are implicit.
ALLOWED_HOSTS = set()

TAILNET_NET = ipaddress.ip_network("100.64.0.0/10")
PRIVATE_NETS = (
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("169.254.0.0/16"),
    TAILNET_NET,
)


def peer_allowed(ip, policy=None):
    """Whether a client at this address may reach the API under the given Host setting."""
    policy = ACCESS_POLICY if policy is None else policy
    if policy == "any":
        return True
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    if getattr(addr, "ipv4_mapped", None):
        addr = addr.ipv4_mapped
    # Both tailscale serve and cloudflared dial from loopback.
    if addr.is_loopback:
        return True
    if policy in ("loopback", "tunnel"):
        return False
    if policy == "tailnet":
        return addr in TAILNET_NET
    return any(addr in net for net in PRIVATE_NETS)


def request_allowed(peer, forwarded_for, policy=None):
    """The peer check, extended through a proxy that dialled us from loopback.

    Accepting every loopback peer is not enough on its own. `tailscale serve` and Tailscale Funnel
    both arrive as 127.0.0.1, but Funnel is fronting the public internet, so a tailnet-only setting
    would have admitted the whole world through it. Any other reverse proxy on this Mac pointed at
    port 8765 does the same. When the proxy tells us who it is relaying for, hold that address to
    the same policy.

    Only from a loopback peer: a direct caller writes its own headers, and believing one would let
    it claim any address it likes. The Cloudflare Tunnel mode is exempt, because fronting a public
    address is the entire point of choosing it; Localhost is not, because "this Mac only" has to
    mean that even when something on this Mac is relaying for someone else.
    """
    policy = ACCESS_POLICY if policy is None else policy
    if not peer_allowed(peer, policy):
        return False
    if policy in ("any", "tunnel"):
        return True
    origin_ip, proxied = client_ip(peer, forwarded_for)
    if proxied or origin_ip == peer:
        return True
    return peer_allowed(origin_ip, policy)


def split_host(host_header):
    """Hostname from a Host header, minus the port and any brackets around an IPv6 literal."""
    host = (host_header or "").strip()
    if host.startswith("["):
        return host[1:].split("]", 1)[0]
    return host.rsplit(":", 1)[0] if host.count(":") == 1 else host


def host_allowed(host_header, extra=None):
    """Whether this Host is one we are legitimately reachable at.

    A name resolves to whatever its owner says it does, so a page on attacker.example can point
    that name at this Mac and have the browser treat the result as same-origin (DNS rebinding),
    slipping past the origin check below. Answering only to the addresses Toki actually hands out
    closes that: an attacker cannot make a browser send a Host it does not control.
    """
    host = split_host(host_header).lower().rstrip(".")
    if not host:
        return False
    if host in ("localhost", "localhost.localdomain"):
        return True
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        pass
    if host.endswith(".ts.net") or host.endswith(".trycloudflare.com"):
        return True
    return host in (ALLOWED_HOSTS if extra is None else extra)


def origin_allowed(origin, host_header):
    """Whether a browser at this Origin may make a state-changing call.

    No Origin at all means a non-browser client (curl, a native app), which no website can forge
    on a user's behalf. Everything else must be either the hosted UI or the page we served.
    """
    if not origin:
        return True
    if origin == HOSTED_ORIGIN:
        return True
    stripped = origin.split("://", 1)[-1].lower().rstrip(".")
    host = (host_header or "").strip().lower().rstrip(".")
    return bool(host) and stripped == host

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
WEBUI_DIR = os.path.join(_SCRIPT_DIR, "webui")
if not os.path.isdir(WEBUI_DIR):
    # `swift run` flattens processed resources beside the script.
    WEBUI_DIR = _SCRIPT_DIR


# Device management stays on Toki's stdin/stdout pipe, outside the phone's HTTP surface.

_last_published = None
# Serialize snapshot-and-print so a timer cannot republish pre-revocation state. Lock order is
# PUBLISH_LOCK then AUTH_LOCK.
PUBLISH_LOCK = threading.Lock()


def device_list():
    now = time.time()
    with AUTH_LOCK:
        for token in [t for t, d in SESSIONS.items() if d["expires"] <= now]:
            del SESSIONS[token]
        return sorted(
            (
                {
                    "id": d["id"],
                    "name": d["name"],
                    "ip": d["ip"],
                    "proxied": d["proxied"],
                    "paired": int(d["paired"]),
                    "seen": int(d["seen"]),
                    "expires": int(d["expires"]),
                }
                for d in SESSIONS.values()
            ),
            key=lambda d: d["paired"],
        )


def publish_devices(force=False):
    """Emit the device list when it has changed, for Toki to display."""
    global _last_published
    with PUBLISH_LOCK:
        payload = json.dumps({"devices": device_list()}, sort_keys=True)
        if payload == _last_published and not force:
            return
        _last_published = payload
        print("devices=" + payload, flush=True)


def revoke_device(device_id):
    """Drop the session with this id. Its next request fails auth and the phone returns to pairing."""
    with AUTH_LOCK:
        for token, entry in list(SESSIONS.items()):
            if entry["id"] == device_id:
                del SESSIONS[token]
                return True
    return False


def watch_devices():
    # Polling changes last-seen and expiry can pass without another event.
    while True:
        time.sleep(5)
        publish_devices()


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
        # CORS varies by request origin, so caches must not reuse another origin's response.
        self.send_header("Vary", "Origin")
        if self.headers.get("Origin") == HOSTED_ORIGIN:
            self.send_header("Access-Control-Allow-Origin", HOSTED_ORIGIN)

    def _secure(self, document=False):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        if document:
            self.send_header("Content-Security-Policy", CSP)
            self.send_header("X-Frame-Options", "DENY")
            # Connect URLs carry the token; keep them out of browser and edge caches.
            self.send_header("Cache-Control", "no-store")

    def _gate(self):
        """Reject the request unless the peer and the Host it asked for are both permitted."""
        if not request_allowed(self.client_address[0], self.headers.get("X-Forwarded-For")):
            self._json({"error": "not reachable from this network"}, 403)
            return False
        if not host_allowed(self.headers.get("Host")):
            self._json({"error": "unrecognised host"}, 421)
            return False
        return True

    def _read_body(self, max_bytes=MAX_BODY_BYTES):
        try:
            length = int(self.headers.get("Content-Length", 0))
        except (TypeError, ValueError):
            return None
        if length < 0 or length > max_bytes:
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

    def _presented_token(self, q):
        """Session token from the Authorization header, falling back to the query string.

        The header is preferred because a query string is the one part of a request that gets
        written down elsewhere: browser history on the phone, and the request line in any proxy
        log between the two -- including Cloudflare's, on the tunnel path. Query tokens stay
        supported so an opened connect link still authenticates before the app takes over.
        """
        auth = self.headers.get("Authorization", "")
        if auth.startswith("Bearer "):
            return auth[7:].strip()
        return q.get("token", [""])[0]

    def _authed(self, q):
        candidate = self._presented_token(q)
        if not candidate:
            return False
        now = time.time()
        ip, _ = client_ip(self.client_address[0], self.headers.get("X-Forwarded-For"))
        with AUTH_LOCK:
            for token in [t for t, d in SESSIONS.items() if d["expires"] <= now]:
                del SESSIONS[token]
            # Compare every live token in constant time rather than exposing dict lookup timing.
            match = next(
                (d for t, d in SESSIONS.items() if secrets.compare_digest(candidate, t)),
                None,
            )
            if match is None:
                return False
            match["seen"] = now
            match["ip"] = ip
            return True

    def _pair(self, q):
        if not origin_allowed(self.headers.get("Origin"), self.headers.get("Host")):
            return self._json({"error": "cross-origin request not allowed"}, 403)
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
            # Key failures by direct peer, not a spoofable forwarded address. Proxied phones share
            # a bucket (a limited DoS risk), but attacker-chosen keys would permit unlimited guesses.
            # Prune every expired bucket so unique peers cannot grow the table forever.
            for address in [a for a, tries in PAIRING_FAILURES.items()
                            if not any(t > now - PAIRING_WINDOW for t in tries)]:
                del PAIRING_FAILURES[address]
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
            for token, _ in sorted(SESSIONS.items(), key=lambda item: item[1]["expires"]):
                if len(SESSIONS) < MAX_SESSIONS:
                    break
                del SESSIONS[token]
            session_token = secrets.token_urlsafe(32)
            ip, via_proxy = client_ip(client, self.headers.get("X-Forwarded-For"))
            SESSIONS[session_token] = {
                "id": secrets.token_hex(4),
                "name": device_name(self.headers.get("User-Agent")),
                "ip": ip,
                "proxied": via_proxy,
                "paired": now,
                "seen": now,
                "expires": now + SESSION_TTL,
            }
        publish_devices()

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
        if not self._gate():
            return
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
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.send_header("Access-Control-Max-Age", "600")
        self.end_headers()

    def do_GET(self):
        if not self._gate():
            return
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
            agents.sort(key=agent_order, reverse=True)
            for a in agents:
                att = None
                if a["session"]:
                    if a["provider"] == "claude":
                        att = claude_attention(a["session"])
                    elif a["provider"] == "codex":
                        att = codex_attention(a["session"])
                    elif a["provider"] == "antigravity":
                        att = agy_attention(a["session"])
                    elif a["provider"] == "opencode":
                        att = opencode_attention(a["session"])
                    # fx has no attention parser yet; leave it None rather than misreading it
                    # through opencode's, which expects a session id and not a transcript path.
                result.append({
                    "pid": a["pid"], "tty": a["tty"], "cwd": a["cwd"],
                    "path": display_path(a["cwd"]),
                    "provider": a["provider"],
                    "title": a.get("title") or chat_title(a["provider"], a["session"], a["cwd"]),
                    "attention": att,
                    "model": model_of(a),
                    "writable": agent_is_writable(a),
                    "machine": machine_name(),
                    # Lets newer hosted UIs hide uploads when connected to an older server.
                    "uploads": True,
                    # Signals /api/screen support so older servers do not expose model control.
                    "screen": True,
                })
            self._json(result)
        elif url.path == "/api/screen":
            pid = int_param(q, "pid")
            agent = next((a for a in discover_agents() if a["pid"] == pid), None)
            if not agent:
                return self._json({"error": "agent gone"}, 410)
            if not agent_is_writable(agent):
                return self._json({"error": "This non-terminal session has no screen to read."}, 422)
            text = capture_screen(agent["tty"])
            if text is None:
                return self._json({"ok": False, "error": "no route to tty (not tmux/iTerm/Terminal?)"})
            self._json({"ok": True, "text": text})
        elif url.path == "/api/usage":
            self._json(current_usage())
        elif url.path == "/api/transcript":
            pid = int_param(q, "pid")
            offset = int_param(q, "offset")
            agent = next((a for a in discover_agents() if a["pid"] == pid), None)
            session = transcript_id(agent)
            if not agent or not agent["session"]:
                return self._json({"entries": [], "offset": offset, "session": session})
            if agent["provider"] == "opencode":
                entries = opencode_entries(agent["session"])
                if offset > len(entries):  # session changed under us
                    return self._json({"entries": [], "offset": 0, "reset": True, "session": session})
                shown = initial_transcript_window(entries) if offset == 0 else entries[offset:]
                return self._json({"entries": shown, "offset": len(entries), "session": session})
            try:
                size = os.path.getsize(agent["session"])
            except OSError:
                size = 0
            if offset > size:  # session file rotated/replaced
                return self._json({"entries": [], "offset": 0, "reset": True, "session": session})
            parse = TRANSCRIPT_PARSERS.get(agent["provider"], parse_codex_transcript)
            entries, new_offset = parse(agent["session"], offset)
            if offset == 0:
                entries = initial_transcript_window(entries)
            self._json({"entries": entries, "offset": new_offset, "session": session})
        else:
            self._json({"error": "not found"}, 404)

    def _upload(self):
        """Save an attached image on the Mac and hand its path back, for a reply to reference so the
        agent can read the picture. Only a paired device reaches here, and only bytes that sniff as a
        real image are written. A semaphore bounds how many large bodies are buffered at once."""
        if not UPLOAD_SLOTS.acquire(timeout=UPLOAD_SLOT_TIMEOUT):
            return self._json({"error": "too many uploads in progress"}, 503)
        try:
            return self._upload_locked()
        finally:
            UPLOAD_SLOTS.release()

    def _upload_locked(self):
        raw = self._read_body(MAX_UPLOAD_BODY_BYTES)
        if raw is None:
            return self._json({"error": "image too large"}, 413)
        try:
            body = json.loads(raw)
        except ValueError:
            return self._json({"error": "bad json"}, 400)
        if not isinstance(body, dict):
            return self._json({"error": "bad json"}, 400)
        data = decode_image_payload(body.get("image"))
        if data is None or not image_extension(data):
            return self._json({"error": "not a supported image, or too large"}, 415)
        path = save_upload(data)
        if not path:
            return self._json({"error": "could not save image"}, 500)
        self._json({"path": path}, 200)

    def do_POST(self):
        if not self._gate():
            return
        url = urlparse(self.path)
        q = parse_qs(url.query)
        if url.path == "/api/pair":
            return self._pair(q)
        if not self._authed(q):
            return self._json({"error": "bad token"}, 403)
        if url.path not in ("/api/send", "/api/upload"):
            return self._json({"error": "not found"}, 404)
        # Simple POSTs skip CORS preflight; still bind state changes to an allowed origin.
        if not origin_allowed(self.headers.get("Origin"), self.headers.get("Host")):
            return self._json({"error": "cross-origin request not allowed"}, 403)
        if url.path == "/api/upload":
            return self._upload()
        raw = self._read_body()
        if raw is None:
            return self._json({"error": "request too large"}, 413)
        try:
            body = json.loads(raw)
        except ValueError:
            return self._json({"error": "bad json"}, 400)
        # Validate before discovery shells out to ps and lsof.
        key = body.get("key")
        text = body.get("text")
        keys = body.get("keys")
        if key not in (None,) + NAMED_KEYS:
            return self._json({"error": "unknown key"}, 400)
        if keys is not None:
            if key is not None or text is not None or body.get("raw") is not None:
                return self._json({"error": "keys cannot be combined with key/text/raw"}, 400)
            if not isinstance(keys, list) or not keys or len(keys) > MAX_SEQ_KEYS:
                return self._json({"error": "bad key sequence"}, 400)
            if not all(isinstance(k, str) and (k in NAMED_KEYS or len(k) == 1) for k in keys):
                return self._json({"error": "bad key in sequence"}, 400)
        elif not key and not (isinstance(text, str) and text):
            return self._json({"error": "nothing to send"}, 400)
        if isinstance(text, str) and len(text) > MAX_SEND_CHARS:
            return self._json({"error": "message too long"}, 413)
        agent = next((a for a in discover_agents() if a["pid"] == body.get("pid")), None)
        if not agent:
            return self._json({"error": "agent gone"}, 410)
        if not agent_is_writable(agent):
            return self._json({"error": "This non-terminal session is read-only."}, 422)
        if keys is not None:
            ok, how = send_sequence(agent["tty"], keys)
        else:
            raw = bool(body.get("raw")) and text is not None and len(text) == 1
            ok, how = send_input(agent["tty"], text=text, key=key, raw=raw)
        self._json({"ok": ok, "how": how}, 200 if ok else 502)


class RemoteControlHTTPServer(ThreadingHTTPServer):
    """Threading server that binds without a reverse DNS lookup.

    HTTPServer.server_bind() resolves the address it just bound with getfqdn(), and on a network
    whose DNS does not answer -- a captive portal, a hotel, a CI runner -- that call can sit there
    for many seconds. It happens before anything is served or printed, so Toki sees a server that
    launched and then went quiet, with no token and no error to show. Nothing here uses the name.
    """

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


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
    global CANONICAL_AGENTS, CANONICAL_AGENTS_AT, SESSION_TTL, ACCESS_POLICY, ALLOWED_HOSTS
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--access", choices=ACCESS_POLICIES, default=ACCESS_POLICY,
                    help="which peers may reach the API: loopback, tailnet, private, or any")
    ap.add_argument("--allow-host", action="append", default=[],
                    help="an extra Host header value to answer to (repeatable)")
    ap.add_argument("--session-ttl", type=int, choices=SESSION_TTL_CHOICES, default=SESSION_TTL)
    ap.add_argument("--agent-snapshot-stdin", action="store_true")
    ap.add_argument("--no-qr", action="store_true")
    args = ap.parse_args()
    SESSION_TTL = args.session_ttl
    ACCESS_POLICY = args.access
    ALLOWED_HOSTS = {h.strip().lower().rstrip(".") for h in args.allow_host if h.strip()}
    if args.agent_snapshot_stdin:
        CANONICAL_AGENTS = []
        CANONICAL_AGENTS_AT = time.time()
        threading.Thread(target=read_control_messages, daemon=True).start()
        threading.Thread(target=watch_devices, daemon=True).start()
    server = RemoteControlHTTPServer((args.bind, args.port), Handler)

    ips = [ip for ip in local_ipv4s() if peer_allowed(ip)]
    print(f"toki-remote prototype (access={ACCESS_POLICY}, bind={args.bind})\n")
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
