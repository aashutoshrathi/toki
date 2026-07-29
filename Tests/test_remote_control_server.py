import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


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


if __name__ == "__main__":
    unittest.main()
