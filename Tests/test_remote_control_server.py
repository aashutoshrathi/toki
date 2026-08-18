import collections
import importlib.util
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest import mock


SCRIPT = Path(__file__).parents[1] / "Sources" / "Toki" / "Resources" / "toki_remote.py"
SPEC = importlib.util.spec_from_file_location("toki_remote", SCRIPT)
toki_remote = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(toki_remote)


class RemoteControlTitleTests(unittest.TestCase):
    def setUp(self):
        toki_remote._title_cache.clear()

    def test_recommended_plugins_message_is_not_user_text(self):
        text = "<recommended_plugins>\n- Example plugin\n</recommended_plugins>"
        self.assertIsNone(toki_remote.clean_user_text(text))

    def test_agents_instructions_are_not_user_text(self):
        text = "# AGENTS.md instructions\n\n<INSTRUCTIONS>\n@RTK.md\n</INSTRUCTIONS>"
        self.assertIsNone(toki_remote.clean_user_text(text))

    def test_codex_file_envelope_keeps_only_the_actual_request(self):
        text = (
            "# Files mentioned by the user:\n\n"
            "## screenshot.png\n\n"
            "## My request for Codex:\n"
            "Fix the duplicate chat names"
        )
        self.assertEqual(
            toki_remote.clean_user_text(text),
            "Fix the duplicate chat names",
        )

    def test_codex_title_skips_recommended_plugins_message(self):
        entries = [
            {
                "type": "response_item",
                "payload": {
                    "type": "message",
                    "role": "user",
                    "content": [{"type": "input_text", "text": "<recommended_plugins>noise</recommended_plugins>"}],
                },
            },
            {
                "type": "response_item",
                "payload": {
                    "type": "message",
                    "role": "user",
                    "content": [{"type": "input_text", "text": "Fix the remote control title"}],
                },
            },
        ]
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl") as transcript:
            for entry in entries:
                transcript.write(json.dumps(entry) + "\n")
            transcript.flush()
            self.assertEqual(
                toki_remote.chat_title("codex", transcript.name, "/tmp/toki"),
                "Fix the remote control title",
            )

    def test_claude_title_rejects_harness_generated_ai_title(self):
        entries = [
            {"aiTitle": "<recommended_plugins> noise"},
            {
                "type": "user",
                "message": {
                    "content": "Use the actual request",
                },
            },
        ]
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl") as transcript:
            for entry in entries:
                transcript.write(json.dumps(entry) + "\n")
            transcript.flush()
            self.assertEqual(
                toki_remote.chat_title("claude", transcript.name, "/tmp/toki"),
                "Use the actual request",
            )


class RemoteControlPairingTests(unittest.TestCase):
    def test_pairing_code_rotation_interval_is_two_minutes(self):
        self.assertEqual(toki_remote.PAIRING_CODE_TTL, 2 * 60)

    def test_pairing_code_is_always_six_digits(self):
        with mock.patch.object(toki_remote.secrets, "randbelow", return_value=42):
            self.assertEqual(toki_remote.new_pairing_code(), "000042")


class RemoteControlAccessPolicyTests(unittest.TestCase):
    def test_loopback_reaches_every_policy(self):
        # tailscale serve and cloudflared both dial 127.0.0.1, so no policy may exclude it.
        for policy in toki_remote.ACCESS_POLICIES:
            self.assertTrue(toki_remote.peer_allowed("127.0.0.1", policy), policy)

    def test_localhost_policy_excludes_the_local_network(self):
        self.assertFalse(toki_remote.peer_allowed("192.168.1.20", "loopback"))
        self.assertFalse(toki_remote.peer_allowed("100.101.102.103", "loopback"))

    def test_tailnet_policy_admits_only_the_tailnet(self):
        self.assertTrue(toki_remote.peer_allowed("100.101.102.103", "tailnet"))
        # The whole point: choosing Tailscale must not leave the port open to the cafe Wi-Fi.
        self.assertFalse(toki_remote.peer_allowed("192.168.1.20", "tailnet"))
        self.assertFalse(toki_remote.peer_allowed("8.8.8.8", "tailnet"))

    def test_private_policy_admits_lan_and_tailnet_but_not_the_internet(self):
        for ip in ("192.168.1.20", "10.1.2.3", "172.16.5.5", "100.101.102.103"):
            self.assertTrue(toki_remote.peer_allowed(ip, "private"), ip)
        self.assertFalse(toki_remote.peer_allowed("8.8.8.8", "private"))

    def test_ipv4_mapped_address_is_judged_as_ipv4(self):
        self.assertFalse(toki_remote.peer_allowed("::ffff:192.168.1.20", "tailnet"))
        self.assertTrue(toki_remote.peer_allowed("::ffff:100.101.102.103", "tailnet"))

    def test_a_proxy_cannot_smuggle_the_public_internet_into_the_tailnet(self):
        # Tailscale Funnel and `tailscale serve` both arrive as 127.0.0.1, but Funnel is fronting
        # the public internet. Accepting every loopback peer would admit the world through it.
        self.assertFalse(
            toki_remote.request_allowed("127.0.0.1", "203.0.113.9", "tailnet")
        )
        self.assertTrue(
            toki_remote.request_allowed("127.0.0.1", "100.101.102.103", "tailnet")
        )
        # A LAN address is not the tailnet either, however it reaches us.
        self.assertFalse(
            toki_remote.request_allowed("127.0.0.1", "192.168.1.20", "tailnet")
        )

    def test_a_proxy_with_nothing_to_declare_is_still_accepted(self):
        # No forwarded address means nothing to judge; refusing here would break `tailscale serve`.
        self.assertTrue(toki_remote.request_allowed("127.0.0.1", None, "tailnet"))
        self.assertTrue(toki_remote.request_allowed("127.0.0.1", "", "tailnet"))

    def test_the_tunnel_mode_is_deliberately_exempt(self):
        # Fronting a public address is the whole point of choosing Cloudflare Tunnel.
        self.assertTrue(toki_remote.request_allowed("127.0.0.1", "203.0.113.9", "tunnel"))

    def test_localhost_means_this_mac_even_through_a_relay(self):
        # Localhost and the tunnel both only ever see loopback peers, but they promise different
        # things. Something on this Mac relaying a stranger in breaks "this Mac only".
        self.assertFalse(toki_remote.request_allowed("127.0.0.1", "203.0.113.9", "loopback"))
        self.assertFalse(toki_remote.request_allowed("127.0.0.1", "192.168.1.20", "loopback"))
        self.assertFalse(toki_remote.request_allowed("127.0.0.1", "100.101.102.103", "loopback"))
        # A browser on this Mac, relayed or not, is still this Mac.
        self.assertTrue(toki_remote.request_allowed("127.0.0.1", "127.0.0.1", "loopback"))
        self.assertTrue(toki_remote.request_allowed("127.0.0.1", None, "loopback"))

    def test_a_direct_caller_cannot_talk_its_way_in_with_a_header(self):
        # Believing a non-loopback peer's own header would let it claim any address it likes.
        self.assertFalse(
            toki_remote.request_allowed("203.0.113.9", "100.101.102.103", "tailnet")
        )
        self.assertTrue(
            toki_remote.request_allowed("100.101.102.103", "203.0.113.9", "tailnet")
        )

    def test_unparseable_peer_is_refused_unless_the_policy_is_open(self):
        self.assertFalse(toki_remote.peer_allowed("not-an-address", "tailnet"))
        self.assertTrue(toki_remote.peer_allowed("not-an-address", "any"))


class RemoteControlHostAndOriginTests(unittest.TestCase):
    def test_addresses_toki_hands_out_are_accepted(self):
        for host in ("localhost:8765", "127.0.0.1:8765", "100.101.102.103:8765",
                     "mac.tail1234.ts.net", "abc-def.trycloudflare.com"):
            self.assertTrue(toki_remote.host_allowed(host, set()), host)

    def test_a_name_the_attacker_owns_is_rejected(self):
        # DNS rebinding: attacker.example resolves to this Mac, so the browser calls us with that
        # Host and treats the reply as same-origin. Answering only to our own names stops it.
        self.assertFalse(toki_remote.host_allowed("attacker.example", set()))
        self.assertFalse(toki_remote.host_allowed("mac.ts.net.attacker.example", set()))
        self.assertFalse(toki_remote.host_allowed("", set()))

    def test_a_custom_host_is_accepted_once_named(self):
        self.assertFalse(toki_remote.host_allowed("mac.internal", set()))
        self.assertTrue(toki_remote.host_allowed("mac.internal:8765", {"mac.internal"}))

    def test_the_hosted_ui_and_our_own_page_may_post(self):
        self.assertTrue(toki_remote.origin_allowed(toki_remote.HOSTED_ORIGIN, "mac.ts.net"))
        self.assertTrue(toki_remote.origin_allowed("https://mac.ts.net", "mac.ts.net"))
        self.assertTrue(toki_remote.origin_allowed("http://127.0.0.1:8765", "127.0.0.1:8765"))

    def test_any_other_page_may_not_post(self):
        self.assertFalse(toki_remote.origin_allowed("https://evil.example", "mac.ts.net"))
        self.assertFalse(toki_remote.origin_allowed("null", "mac.ts.net"))

    def test_a_request_with_no_origin_is_not_a_browser_and_is_allowed(self):
        self.assertTrue(toki_remote.origin_allowed(None, "mac.ts.net"))
        self.assertTrue(toki_remote.origin_allowed("", "mac.ts.net"))


class RemoteControlDeviceRegistryTests(unittest.TestCase):
    def setUp(self):
        toki_remote.SESSIONS.clear()

    tearDown = setUp

    def test_a_device_is_named_from_what_its_browser_reports(self):
        iphone = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
                  "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")
        self.assertEqual(toki_remote.device_name(iphone), "iPhone (Safari)")
        # Chrome and Edge both claim Safari in their User-Agent, so order decides correctness.
        chrome = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                  "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")
        self.assertEqual(toki_remote.device_name(chrome), "Mac (Chrome)")
        self.assertEqual(toki_remote.device_name(""), "Device")

    def test_a_proxy_is_not_reported_as_the_device(self):
        # tailscale serve and cloudflared dial us from loopback and forward the real address.
        self.assertEqual(toki_remote.client_ip("127.0.0.1", "100.64.1.2"), ("100.64.1.2", False))
        # No forwarded address to fall back on, so say it is a proxy rather than claim loopback.
        self.assertEqual(toki_remote.client_ip("127.0.0.1", None), ("127.0.0.1", True))

    def test_a_direct_peer_cannot_spoof_its_own_address(self):
        # Trusting the header from a non-loopback peer would let a caller pick which rate-limit
        # bucket it lands in.
        self.assertEqual(
            toki_remote.client_ip("192.168.1.20", "10.0.0.1"), ("192.168.1.20", False)
        )

    def test_a_garbled_forwarded_address_is_not_believed(self):
        self.assertEqual(toki_remote.client_ip("127.0.0.1", "not-an-ip"), ("127.0.0.1", True))

    def test_the_published_list_never_carries_a_session_token(self):
        toki_remote.SESSIONS["super-secret-token"] = {
            "id": "a1b2c3d4", "name": "iPhone (Safari)", "ip": "100.64.1.2", "proxied": False,
            "paired": 1000.0, "seen": 1200.4, "expires": time.time() + 600,
        }
        listed = toki_remote.device_list()
        self.assertEqual(len(listed), 1)
        self.assertNotIn("super-secret-token", json.dumps(listed))
        self.assertEqual(listed[0]["id"], "a1b2c3d4")
        self.assertEqual(listed[0]["seen"], 1200)

    def test_an_expired_session_drops_off_the_list(self):
        toki_remote.SESSIONS["stale"] = {
            "id": "dead", "name": "iPad", "ip": "100.64.1.3", "proxied": False,
            "paired": 0.0, "seen": 0.0, "expires": time.time() - 1,
        }
        self.assertEqual(toki_remote.device_list(), [])

    def test_revoking_removes_exactly_one_device(self):
        for token, ident in (("t1", "keep0001"), ("t2", "drop0002")):
            toki_remote.SESSIONS[token] = {
                "id": ident, "name": "iPhone", "ip": "100.64.1.2", "proxied": False,
                "paired": 1000.0, "seen": 1000.0, "expires": time.time() + 600,
            }
        self.assertTrue(toki_remote.revoke_device("drop0002"))
        self.assertEqual([d["id"] for d in toki_remote.device_list()], ["keep0001"])
        # A second revoke of the same id is a no-op rather than an error.
        self.assertFalse(toki_remote.revoke_device("drop0002"))


class RemoteControlInputBoundsTests(unittest.TestCase):
    def test_malformed_numbers_fall_back_instead_of_raising(self):
        self.assertEqual(toki_remote.int_param({"pid": ["abc"]}, "pid"), 0)
        self.assertEqual(toki_remote.int_param({}, "offset"), 0)
        self.assertEqual(toki_remote.int_param({"offset": ["-5"]}, "offset"), 0)
        self.assertEqual(toki_remote.int_param({"pid": ["4242"]}, "pid"), 4242)

    def test_a_reply_is_bounded_well_below_the_body_cap(self):
        self.assertLess(toki_remote.MAX_SEND_CHARS, toki_remote.MAX_BODY_BYTES)

    def test_a_newline_survives_applescript_quoting(self):
        # A raw newline is a compile error inside an AppleScript literal, which lost the message.
        quoted = toki_remote.applescript_str("first\nsecond")
        self.assertEqual(quoted, '"first\\nsecond"')
        self.assertNotIn("\n", quoted)

    def test_quotes_and_backslashes_cannot_end_the_literal(self):
        self.assertEqual(toki_remote.applescript_str('a"b\\c'), '"a\\"b\\\\c"')


class RemoteControlAgentDiscoveryTests(unittest.TestCase):
    def test_agents_resolving_to_same_session_are_collapsed(self):
        agents = [
            {"pid": 10, "provider": "codex", "session": "/tmp/session.jsonl", "tty": None},
            {"pid": 11, "provider": "codex", "session": "/tmp/session.jsonl", "tty": "ttys001"},
            {"pid": 12, "provider": "codex", "session": "/tmp/other.jsonl", "tty": "ttys002"},
        ]
        result = toki_remote.dedupe_agents(agents)
        self.assertEqual([agent["pid"] for agent in result], [11, 12])

    def test_canonical_snapshot_filters_process_discovery(self):
        processes = [
            {"pid": 10, "ppid": 1, "provider": "codex", "command": "codex", "tty": None},
            {"pid": 11, "ppid": 1, "provider": "codex", "command": "codex", "tty": None},
        ]
        snapshot = [
            {
                "pid": 11,
                "provider": "codex",
                "cwd": None,
                "title": "The actual session",
                "tty": None,
            }
        ]
        with mock.patch.object(
            toki_remote,
            "newest_codex_session",
            return_value="/tmp/session.jsonl",
        ):
            result = toki_remote.agents_from_snapshot(processes, snapshot)
        self.assertEqual([agent["pid"] for agent in result], [11])
        self.assertEqual(result[0]["title"], "The actual session")

    def test_non_terminal_agent_is_read_only(self):
        self.assertFalse(toki_remote.agent_is_writable({"tty": None}))
        self.assertTrue(toki_remote.agent_is_writable({"tty": "ttys001"}))


class RemoteControlAgentOrderTests(unittest.TestCase):
    def order(self, agents):
        with mock.patch.object(toki_remote, "agent_recency", lambda a: a["recency"]):
            return [a["pid"] for a in sorted(agents, key=toki_remote.agent_order, reverse=True)]

    def test_writable_agents_come_before_read_only_ones(self):
        agents = [
            {"pid": 1, "tty": None, "recency": 900},        # read-only, but the most recent
            {"pid": 2, "tty": "ttys001", "recency": 100},
            {"pid": 3, "tty": None, "recency": 800},
            {"pid": 4, "tty": "ttys002", "recency": 200},
        ]
        self.assertEqual(self.order(agents), [4, 2, 1, 3])

    def test_recency_still_orders_within_each_group(self):
        agents = [
            {"pid": 1, "tty": "ttys001", "recency": 100},
            {"pid": 2, "tty": "ttys002", "recency": 300},
            {"pid": 3, "tty": "ttys003", "recency": 200},
        ]
        self.assertEqual(self.order(agents), [2, 3, 1])


class RemoteControlTranscriptIdTests(unittest.TestCase):
    def test_two_transcripts_have_different_ids(self):
        with tempfile.NamedTemporaryFile(suffix=".jsonl") as first, \
             tempfile.NamedTemporaryFile(suffix=".jsonl") as second:
            a = toki_remote.transcript_id({"session": first.name})
            b = toki_remote.transcript_id({"session": second.name})
            self.assertNotEqual(a, b)

    def test_id_is_stable_while_the_file_grows(self):
        # The point of using the inode: /clear has to be detectable even when the new transcript
        # overtakes the old offset between polls, which size comparisons miss.
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl") as transcript:
            before = toki_remote.transcript_id({"session": transcript.name})
            transcript.write("x" * 4096)
            transcript.flush()
            self.assertEqual(toki_remote.transcript_id({"session": transcript.name}), before)

    def test_an_id_survives_a_session_that_is_not_a_file(self):
        # OpenCode's "session" is a database id, not a path, and already identifies itself.
        self.assertEqual(toki_remote.transcript_id({"session": "ses_abc123"}), "ses_abc123")

    def test_no_agent_and_no_session_have_no_id(self):
        self.assertEqual(toki_remote.transcript_id(None), "")
        self.assertEqual(toki_remote.transcript_id({"session": None}), "")


class RemoteControlDisplayPathTests(unittest.TestCase):
    def test_home_is_collapsed_to_a_tilde(self):
        with mock.patch.object(toki_remote, "HOME", "/Users/someone"):
            self.assertEqual(toki_remote.display_path("/Users/someone/Git/toki"), "~/Git/toki")
            self.assertEqual(toki_remote.display_path("/Users/someone"), "~")

    def test_path_outside_home_is_left_alone(self):
        with mock.patch.object(toki_remote, "HOME", "/Users/someone"):
            self.assertEqual(toki_remote.display_path("/opt/work/api"), "/opt/work/api")

    def test_a_sibling_home_is_not_mistaken_for_yours(self):
        # "/Users/someone2" starts with "/Users/someone" but is a different account's folder.
        with mock.patch.object(toki_remote, "HOME", "/Users/someone"):
            self.assertEqual(toki_remote.display_path("/Users/someone2/Git"), "/Users/someone2/Git")

    def test_an_agent_with_no_folder_has_no_path(self):
        self.assertEqual(toki_remote.display_path(None), "")
        self.assertEqual(toki_remote.display_path(""), "")


class ClaudeToolEntryTests(unittest.TestCase):
    """What a tool call sends to the phone: enough to follow it, never its output."""

    def _entries(self, lines):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as handle:
            for line in lines:
                handle.write(json.dumps(line) + "\n")
            path = handle.name
        entries, _ = toki_remote.parse_claude_transcript(path, 0)
        return entries

    def test_a_call_carries_its_id_time_and_what_it_is_doing(self):
        entries = self._entries([{
            "type": "assistant",
            "timestamp": "2026-08-11T10:00:00.000Z",
            "message": {"content": [{
                "type": "tool_use", "id": "tu_1", "name": "Bash",
                "input": {"description": "List files", "command": "ls -la /tmp"},
            }]},
        }])
        call = next(e for e in entries if e["role"] == "tool")
        self.assertEqual(call["id"], "tu_1")
        self.assertEqual(call["ts"], "2026-08-11T10:00:00.000Z")
        # The summary picks the description; the detail is what is actually being run.
        self.assertEqual(call["text"], "List files")
        self.assertEqual(call["detail"], "ls -la /tmp")

    def test_a_result_reports_completion_and_failure_but_never_its_output(self):
        entries = self._entries([{
            "type": "user",
            "timestamp": "2026-08-11T10:00:04.000Z",
            "message": {"content": [{
                "type": "tool_result", "tool_use_id": "tu_1", "is_error": True,
                "content": "SECRET_TOKEN=hunter2 leaked all over stdout",
            }]},
        }])
        resolved = next(e for e in entries if e["role"] == "resolved")
        self.assertEqual(resolved["id"], "tu_1")
        self.assertEqual(resolved["ts"], "2026-08-11T10:00:04.000Z")
        self.assertTrue(resolved["failed"])
        # Tool output is where file contents and command output live; none of it leaves the Mac.
        self.assertNotIn("hunter2", json.dumps(resolved))

    def test_detail_does_not_repeat_the_summary(self):
        self.assertEqual(toki_remote.claude_tool_detail("Bash", {"command": "ls"}), "")
        self.assertEqual(
            toki_remote.claude_tool_detail("Grep", {"pattern": "todo", "path": "src"}),
            "src",
        )

    def test_detail_is_bounded(self):
        detail = toki_remote.claude_tool_detail("Bash", {"description": "x", "command": "y" * 900})
        self.assertLessEqual(len(detail), 240)


class UsageSnapshotTests(unittest.TestCase):
    """Usage reaches the phone over the same pipe as agents, and ages the same way."""

    def setUp(self):
        toki_remote.USAGE_SNAPSHOT = []
        toki_remote.USAGE_SNAPSHOT_AT = 0.0

    def test_nothing_published_yet_is_waiting_not_empty(self):
        # An empty list and "the Mac has not told us yet" are different things to draw.
        result = toki_remote.current_usage()
        self.assertTrue(result["waiting"])
        self.assertFalse(result["stale"])
        self.assertEqual(result["accounts"], [])

    def test_a_fresh_publish_is_served_verbatim(self):
        toki_remote.USAGE_SNAPSHOT = [{"id": "claude-code", "name": "Claude Code", "remaining": 0.42}]
        toki_remote.USAGE_SNAPSHOT_AT = time.time()
        result = toki_remote.current_usage()
        self.assertFalse(result["stale"])
        self.assertFalse(result["waiting"])
        self.assertEqual(result["accounts"][0]["remaining"], 0.42)

    def test_a_reading_the_mac_stopped_refreshing_is_marked_stale(self):
        # Worse than no reading, because it looks current: the phone is told so it can say so.
        toki_remote.USAGE_SNAPSHOT = [{"id": "codex", "name": "Codex", "remaining": 0.9}]
        toki_remote.USAGE_SNAPSHOT_AT = time.time() - toki_remote.CANONICAL_MAX_AGE - 1
        self.assertTrue(toki_remote.current_usage()["stale"])


class InitialTranscriptWindowTests(unittest.TestCase):
    def test_a_call_that_finished_before_the_transcript_opened_carries_its_completion(self):
        # The tool finished before the client opened the transcript, so its `resolved` must ride
        # along in the first payload, or the row is stuck `running`.
        entries = [
            {"role": "user", "text": "hi"},
            {"role": "tool", "tool": "Read", "id": "t1"},
            {"role": "resolved", "id": "t1"},
            {"role": "assistant", "text": "done"},
        ]
        shown = toki_remote.initial_transcript_window(entries)
        self.assertIn({"role": "resolved", "id": "t1"}, shown)

    def test_meta_is_dropped_from_the_first_payload(self):
        entries = [
            {"role": "meta", "mode": "default"},
            {"role": "user", "text": "hi"},
        ]
        shown = toki_remote.initial_transcript_window(entries)
        self.assertEqual([e["role"] for e in shown], ["user"])

    def test_only_the_last_visible_messages_are_kept_but_their_resolutions_survive(self):
        entries = []
        for i in range(70):
            entries.append({"role": "user", "text": str(i)})
        entries.append({"role": "tool", "tool": "Read", "id": "last"})
        entries.append({"role": "resolved", "id": "last"})
        shown = toki_remote.initial_transcript_window(entries, limit=60)
        visible = [e for e in shown if e["role"] in ("user", "assistant", "tool")]
        self.assertEqual(len(visible), 60)
        self.assertIn({"role": "resolved", "id": "last"}, shown)


class QuestionExtractionTests(unittest.TestCase):
    def test_normalizes_claude_askuserquestion_with_multiselect(self):
        inp = {
            "questions": [
                {
                    "question": "Which APIs?",
                    "header": "External APIs",
                    "multiSelect": True,
                    "options": [
                        {"label": "Open Food Facts", "description": "no key"},
                        {"label": "USDA", "description": ""},
                    ],
                }
            ]
        }
        qs = toki_remote.extract_questions("AskUserQuestion", inp)
        self.assertEqual(len(qs), 1)
        self.assertTrue(qs[0]["multi"])
        self.assertEqual(qs[0]["header"], "External APIs")
        self.assertEqual([o["label"] for o in qs[0]["options"]], ["Open Food Facts", "USDA"])
        self.assertEqual(qs[0]["options"][0]["description"], "no key")

    def test_extract_questions_ignores_other_tools(self):
        self.assertIsNone(toki_remote.extract_questions("Bash", {"questions": [{"question": "x"}]}))

    def test_opencode_question_tool_reads_multiple_flag(self):
        pdata = json.dumps({
            "type": "tool",
            "tool": "question",
            "state": {
                "status": "running",
                "input": {
                    "questions": [
                        {"question": "Pick some", "header": "MVP", "multiple": True,
                         "options": [{"label": "A"}, {"label": "B"}]},
                        {"question": "Pick one", "header": "Next", "multiple": False,
                         "options": [{"label": "C"}, {"label": "D"}]},
                    ]
                },
            },
        })
        qs = toki_remote.opencode_questions(pdata)
        self.assertEqual([q["multi"] for q in qs], [True, False])
        self.assertEqual(qs[0]["header"], "MVP")

    def test_question_attention_keeps_first_labels_for_older_clients(self):
        qs = toki_remote.normalize_questions(
            [{"question": "Q", "options": [{"label": "One"}, {"label": "Two"}], "multiple": True}],
            "multiple",
        )
        att = toki_remote.question_attention(qs)
        self.assertEqual(att["kind"], "question")
        self.assertEqual(att["prompt"], "Q")
        self.assertEqual(att["options"], ["One", "Two"])
        self.assertEqual(att["questions"], qs)

    def test_string_options_still_normalize(self):
        qs = toki_remote.normalize_questions([{"question": "Q", "options": ["One", "Two"]}], "multiSelect")
        self.assertEqual([o["label"] for o in qs[0]["options"]], ["One", "Two"])
        self.assertFalse(qs[0]["multi"])


class SendSequenceTests(unittest.TestCase):
    def test_sequence_delivers_named_keys_and_characters_in_order(self):
        calls = []

        def fake_send_input(tty, text=None, key=None, raw=False, route=None):
            calls.append((text, key, raw))
            return True, "iterm"

        with mock.patch.object(toki_remote, "tmux_pane_for_tty", lambda tty: (None, None)), \
                mock.patch.object(toki_remote, "send_input", fake_send_input), \
                mock.patch.object(toki_remote.time, "sleep", lambda *_: None):
            ok, how = toki_remote.send_sequence("ttys000", ["1", "enter", "down"])
        self.assertTrue(ok)
        self.assertEqual(how, "iterm")
        self.assertEqual(calls, [("1", None, True), (None, "enter", False), (None, "down", False)])

    def test_sequence_stops_at_first_failure(self):
        calls = []

        def fake_send_input(tty, text=None, key=None, raw=False, route=None):
            calls.append(key or text)
            return (False, "iterm") if (key or text) == "enter" else (True, "iterm")

        with mock.patch.object(toki_remote, "tmux_pane_for_tty", lambda tty: (None, None)), \
                mock.patch.object(toki_remote, "send_input", fake_send_input), \
                mock.patch.object(toki_remote.time, "sleep", lambda *_: None):
            ok, _ = toki_remote.send_sequence("ttys000", ["1", "enter", "down"])
        self.assertFalse(ok)
        self.assertEqual(calls, ["1", "enter"])

    def test_sequence_resolves_the_route_once_and_reuses_it(self):
        # The route is discovered a single time and handed to every send_input, so no key repeats
        # `tmux list-panes` -- whichever route it turns out to be.
        lookups = []

        def fake_pane(tty):
            lookups.append(tty)
            return ("/opt/homebrew/bin/tmux", "%3")

        routes = []

        def fake_send_input(tty, text=None, key=None, raw=False, route=None):
            routes.append(route)
            return True, "tmux"

        with mock.patch.object(toki_remote, "tmux_pane_for_tty", fake_pane), \
                mock.patch.object(toki_remote, "send_input", fake_send_input), \
                mock.patch.object(toki_remote.time, "sleep", lambda *_: None):
            ok, _ = toki_remote.send_sequence("ttys000", ["1", "enter"])
        self.assertTrue(ok)
        self.assertEqual(lookups, ["ttys000"])  # discovered exactly once
        self.assertEqual(routes, [("/opt/homebrew/bin/tmux", "%3"), ("/opt/homebrew/bin/tmux", "%3")])

    def test_sequence_rejects_an_unsafe_tty(self):
        ok, how = toki_remote.send_sequence("../etc/passwd", ["1"])
        self.assertFalse(ok)
        self.assertEqual(how, "unsafe tty")


class MachineNameTests(unittest.TestCase):
    def setUp(self):
        toki_remote._machine_name = None

    def tearDown(self):
        toki_remote._machine_name = None

    def test_prefers_computer_name(self):
        with mock.patch.object(toki_remote, "shell", lambda cmd, timeout=5: "Minato\n"):
            self.assertEqual(toki_remote.machine_name(), "Minato")

    def test_falls_back_to_node_name_without_local_suffix(self):
        Uname = collections.namedtuple("Uname", "sysname nodename release version machine")
        with mock.patch.object(toki_remote, "shell", lambda cmd, timeout=5: None), \
                mock.patch.object(toki_remote.os, "uname",
                                  lambda: Uname("Darwin", "minato.local", "", "", "")):
            self.assertEqual(toki_remote.machine_name(), "minato")

    def test_defaults_when_nothing_is_available(self):
        Uname = collections.namedtuple("Uname", "sysname nodename release version machine")
        with mock.patch.object(toki_remote, "shell", lambda cmd, timeout=5: None), \
                mock.patch.object(toki_remote.os, "uname",
                                  lambda: Uname("Darwin", "", "", "", "")):
            self.assertEqual(toki_remote.machine_name(), "Mac")

    def test_is_cached_after_first_resolution(self):
        calls = []

        def once(cmd, timeout=5):
            calls.append(cmd)
            return "Minato"

        with mock.patch.object(toki_remote, "shell", once):
            toki_remote.machine_name()
            toki_remote.machine_name()
        self.assertEqual(len(calls), 1)


if __name__ == "__main__":
    unittest.main()
