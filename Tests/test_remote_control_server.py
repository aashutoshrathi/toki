import importlib.util
import json
from pathlib import Path
import tempfile
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


if __name__ == "__main__":
    unittest.main()
