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
execution. The random token is required on every request. Only run this
on networks you trust (your tailnet qualifies; a coffee-shop LAN does not).
"""

import argparse
import json
import os
import re
import secrets
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HOME = os.path.expanduser("~")
QUIET_PERIOD = 10.0  # seconds; same reasoning as Toki's attentionQuietPeriod
AUTO_ACCEPTED_EDITS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}

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
    pids = {r["pid"] for r in rows}
    roots = [r for r in rows if r["ppid"] not in pids]
    for r in roots:
        r["cwd"] = cwd_of_pid(r["pid"])
        if r["provider"] == "claude":
            r["session"] = newest_claude_session(r["command"], r["cwd"])
        else:
            r["session"] = newest_codex_session(r["command"], r["cwd"])
    return roots


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


def clean_user_text(text):
    """Strip harness noise from user messages; None means 'do not show'."""
    text = re.sub(r"<system-reminder>.*?</system-reminder>", "", text, flags=re.S).strip()
    if not text:
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


_CODEX_USER_NOISE = ("<user_instructions>", "<environment_context>", "<ENVIRONMENT_CONTEXT>")


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
                        if any(text.startswith(p) for p in _CODEX_USER_NOISE):
                            continue
                        entries.append({"role": "user", "text": text})
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


def chat_title(provider, path, cwd):
    fallback = os.path.basename(cwd) if cwd else provider
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
        title = (custom[-1] if custom else None) or (ai[-1] if ai else None)
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
                ok = ok and shell([tmux, "send-keys", "-t", pane, "Enter"]) is not None
        return ok, "tmux"
    if key:
        seq = {"enter": '(character id 13)', "esc": '(character id 27)',
               "up": '((character id 27) & "[A")', "down": '((character id 27) & "[B")',
               "tab": '(character id 9)'}[key]
        if iterm_write(tty, seq):
            return True, "iterm"
    else:
        expr = applescript_str(text) + ('' if raw else ' & (character id 13)')
        if iterm_write(tty, expr):
            return True, "iterm"
    if focus_terminal_tab(tty):
        time.sleep(0.3)
        if key:
            ok = osascript(f'tell application "System Events" to key code {SYS_EVENTS_KEYCODES[key]}')
        else:
            ok = osascript(f'tell application "System Events" to keystroke {applescript_str(text)}')
            if not raw:
                ok = ok and osascript('tell application "System Events" to key code 36')
        return ok, "terminal+system-events"
    return False, "no route to tty (not tmux/iTerm/Terminal?)"


# ------------------------------------------------------------------- server

TOKEN = secrets.token_urlsafe(24)

PAGE = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>toki remote</title><style>
:root{color-scheme:dark light}
*{box-sizing:border-box;margin:0}
body{font:15px/1.45 -apple-system,system-ui,sans-serif;background:#111;color:#eee;
     padding-bottom:calc(180px + env(safe-area-inset-bottom))}
header{position:sticky;top:0;background:#111c;backdrop-filter:blur(10px);
       padding:12px 14px;border-bottom:1px solid #333;z-index:2}
h1{font-size:16px}
select{width:100%;margin-top:8px;padding:8px;border-radius:8px;background:#222;
       color:#eee;border:1px solid #444;font-size:15px}
#alert{display:none;margin:10px 14px;padding:10px 12px;border-radius:10px;
       background:#5c1f1f;border:1px solid #a33}
#alert.q{background:#1f3a5c;border-color:#37a}
#alert .qq{font-weight:600;margin:4px 0 6px}
.opt{display:inline-block;margin:3px 6px 3px 0;padding:7px 12px;border-radius:8px;
     background:#2a4a72;border:1px solid #58a;color:#fff;font-size:14px}
#log{padding:8px 14px}
.m{margin:8px 0;padding:9px 12px;border-radius:12px;max-width:92%;
   word-break:break-word;overflow-wrap:anywhere}
.user{background:#2a4a2a;margin-left:auto;white-space:pre-wrap}
.assistant{background:#222}
.assistant pre{background:#161620;padding:8px;border-radius:8px;overflow-x:auto;
               font-size:12.5px;margin:6px 0}
.assistant code{background:#161620;padding:1px 4px;border-radius:4px;
                font-family:ui-monospace,monospace;font-size:13px}
.assistant p{margin:5px 0}
.assistant a{color:#8bf}
.tool{background:#1a1a2e;color:#9ab;font-size:13px;font-family:ui-monospace,monospace}
footer{position:fixed;bottom:0;left:0;right:0;background:#161616;
       border-top:1px solid #333;padding:10px 14px calc(10px + env(safe-area-inset-bottom))}
.keys{display:flex;gap:6px;margin-bottom:8px;flex-wrap:wrap}
.keys button{flex:1;min-width:44px;padding:10px 0;border-radius:8px;background:#2b2b2b;
             color:#eee;border:1px solid #444;font-size:15px}
.row{display:flex;gap:6px}
input{flex:1;padding:10px;border-radius:8px;background:#222;color:#eee;
      border:1px solid #444;font-size:16px}
.row button{padding:10px 16px;border-radius:8px;background:#2a4a72;color:#fff;
            border:1px solid #58a;font-size:15px}
#status{font-size:12px;color:#888;margin-top:6px;min-height:14px}
</style></head><body>
<header><h1>&#9201;&#65039; toki remote</h1><select id="agents"></select></header>
<div id="alert"></div><div id="log"></div>
<footer>
  <div class="keys">
    <button data-key="up">&#8593;</button><button data-key="down">&#8595;</button>
    <button data-key="tab">&#8677;</button><button data-key="enter">&#9166;</button>
    <button data-key="esc">esc</button>
    <button data-text="1">1</button><button data-text="2">2</button><button data-text="3">3</button>
  </div>
  <div class="row"><input id="msg" placeholder="Reply to the agent&#8230;">
  <button id="send">Send</button></div>
  <div id="status"></div>
</footer>
<script>
const TOKEN=new URLSearchParams(location.search).get("token")||"";
const $=s=>document.querySelector(s);
let current=null, offset=0, agents=[];
async function api(p,o){const r=await fetch(p+(p.includes("?")?"&":"?")+"token="+TOKEN,o);
  if(!r.ok)throw new Error(await r.text());return r.json()}
function esc(s){const d=document.createElement("div");d.textContent=s;return d.innerHTML}
function md(src){
  // escape, then fenced code, inline code, bold, italic, links, headings, bullets
  let s=esc(src);
  const fences=[];
  s=s.replace(/```[a-zA-Z0-9_-]*\\n([\\s\\S]*?)```/g,(m,c)=>{fences.push(c);return "\\u0000"+(fences.length-1)+"\\u0000"});
  s=s.replace(/`([^`\\n]+)`/g,"<code>$1</code>");
  s=s.replace(/\\*\\*([^*]+)\\*\\*/g,"<b>$1</b>");
  s=s.replace(/(^|[^*])\\*([^*\\n]+)\\*(?!\\*)/g,"$1<i>$2</i>");
  s=s.replace(/\\[([^\\]]+)\\]\\((https?:[^)\\s]+)\\)/g,'<a href="$2" target="_blank">$1</a>');
  s=s.split("\\n").map(line=>{
    if(/^#{1,4}\\s/.test(line))return "<p><b>"+line.replace(/^#{1,4}\\s+/,"")+"</b></p>";
    if(/^\\s*[-*]\\s+/.test(line))return "<p>&bull; "+line.replace(/^\\s*[-*]\\s+/,"")+"</p>";
    if(/^\\s*\\d+\\.\\s+/.test(line))return "<p>"+line+"</p>";
    return line.length?"<p>"+line+"</p>":"";
  }).join("");
  s=s.replace(/\\u0000(\\d+)\\u0000/g,(m,i)=>"<pre>"+fences[+i]+"</pre>");
  return s;
}
async function refreshAgents(){
  agents=await api("/api/agents");const sel=$("#agents"),prev=current;
  sel.innerHTML=agents.map(a=>`<option value="${a.pid}">`+
    `${a.attention?"\\uD83D\\uDD34 ":""}[${a.provider}] ${esc(a.title)}`+
    `${a.tty?" \\u00b7 "+a.tty:""}</option>`).join("")
    ||"<option>no agents found</option>";
  if(agents.length&&!agents.some(a=>a.pid==prev)){current=agents[0].pid;offset=0;$("#log").innerHTML=""}
  else if(prev)sel.value=prev;
  const a=agents.find(x=>x.pid==current), al=$("#alert");
  if(a&&a.attention){
    al.style.display="block";al.className=a.attention.kind=="question"?"q":"";
    const qs=a.attention.questions&&a.attention.questions.length?a.attention.questions
      :[{question:a.attention.prompt||"Agent is waiting on you",options:a.attention.options||[]}];
    al.innerHTML=qs.map(q=>'<div class="qq">'+md(q.question||"")+"</div>"+
      (q.options||[]).map((o,i)=>
        `<button class="opt" data-text="${i+1}">${i+1}. ${esc(o)}</button>`).join("")).join("");
  } else al.style.display="none";
}
async function refreshLog(){
  if(!current)return;
  const r=await api(`/api/transcript?pid=${current}&offset=${offset}`);
  if(r.reset){offset=0;$("#log").innerHTML="";return}
  offset=r.offset;
  for(const e of r.entries){
    if(e.role=="meta"||e.role=="resolved")continue;
    const d=document.createElement("div");d.className="m "+e.role;
    if(e.role=="tool")d.innerHTML="&#128295; <b>"+esc(e.tool)+"</b> "+esc(e.text||"");
    else if(e.role=="assistant")d.innerHTML=md(e.text);
    else d.textContent=e.text;
    $("#log").appendChild(d);
  }
  if(r.entries.length)window.scrollTo(0,document.body.scrollHeight);
}
async function send(body){
  if(!current)return;
  $("#status").textContent="sending\\u2026";
  try{const r=await api("/api/send",{method:"POST",headers:{"Content-Type":"application/json"},
    body:JSON.stringify({pid:current,...body})});
    $("#status").textContent="delivered via "+r.how;
  }catch(e){$("#status").textContent="failed: "+e.message}
  setTimeout(()=>$("#status").textContent="",4000);
}
document.addEventListener("click",e=>{
  const b=e.target.closest("button");if(!b)return;
  if(b.id=="send"){const v=$("#msg").value.trim();if(v){send({text:v});$("#msg").value=""}}
  else if(b.dataset.key)send({key:b.dataset.key});
  else if(b.dataset.text)send({text:b.dataset.text,raw:true});
});
$("#msg").addEventListener("keydown",e=>{if(e.key=="Enter")$("#send").click()});
$("#agents").addEventListener("change",e=>{current=+e.target.value;offset=0;$("#log").innerHTML=""});
refreshAgents();refreshLog();
setInterval(refreshAgents,4000);setInterval(refreshLog,2500);
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self, q):
        return secrets.compare_digest(q.get("token", [""])[0], TOKEN)

    def do_GET(self):
        url = urlparse(self.path)
        q = parse_qs(url.query)
        if not self._authed(q):
            return self._json({"error": "bad token"}, 403)
        if url.path == "/":
            body = PAGE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif url.path == "/api/agents":
            result = []
            for a in discover_agents():
                att = None
                if a["session"]:
                    att = (claude_attention if a["provider"] == "claude" else codex_attention)(a["session"])
                result.append({
                    "pid": a["pid"], "tty": a["tty"], "cwd": a["cwd"],
                    "provider": a["provider"],
                    "title": chat_title(a["provider"], a["session"], a["cwd"]),
                    "attention": att,
                })
            self._json(result)
        elif url.path == "/api/transcript":
            pid = int(q.get("pid", ["0"])[0])
            offset = int(q.get("offset", ["0"])[0])
            agent = next((a for a in discover_agents() if a["pid"] == pid), None)
            if not agent or not agent["session"]:
                return self._json({"entries": [], "offset": offset})
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
        if not self._authed(q):
            return self._json({"error": "bad token"}, 403)
        if url.path != "/api/send":
            return self._json({"error": "not found"}, 404)
        length = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(length))
        except ValueError:
            return self._json({"error": "bad json"}, 400)
        agent = next((a for a in discover_agents() if a["pid"] == body.get("pid")), None)
        if not agent:
            return self._json({"error": "agent gone"}, 410)
        if not agent["tty"]:
            return self._json({"error": "agent has no tty"}, 422)
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
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--no-qr", action="store_true")
    args = ap.parse_args()
    server = ThreadingHTTPServer((args.bind, args.port), Handler)

    ips = local_ipv4s()
    print("toki-remote prototype\n")
    urls = [f"http://{ip}:{args.port}/?token={TOKEN}" for ip in ips]
    for u in urls:
        print("   " + u)
    print(f"   http://localhost:{args.port}/?token={TOKEN}\n")
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
