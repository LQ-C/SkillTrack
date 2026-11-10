import unittest
from unittest.mock import patch

from skilltrack_speech.config import Config
from skilltrack_speech.supabase_gateway import SupabaseGateway
from skilltrack_speech.worker import run_forever


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.config = Config("https://example.supabase.co", "fake-key",
                             video_bucket="videos", discovery_batch_size=2)
        self.gateway = SupabaseGateway(self.config)
        self.url = "https://example.supabase.co/storage/v1/object/public/videos/a%20b.mp4"

    def test_stable_project_urls_only(self):
        self.assertEqual(self.gateway._video_path(self.url), "a b.mp4")
        self.assertEqual(self.gateway._video_path(self.url.replace("/public/", "/authenticated/")),
                         "a b.mp4")
        for url in (None, "https://youtube.com/watch?v=x",
                    self.url.replace("example.supabase.co", "evil.example"),
                    self.url.replace("/videos/", "/other/"),
                    self.url.replace("/public/", "/sign/"),
                    self.url + "?token=secret", self.url + "#fragment",
                    self.url.replace("a%20b.mp4", "%2e%2e/file.mp4"),
                    self.url.replace("https://", "http://")):
            with self.subTest(url=url):
                self.assertIsNone(self.gateway._video_path(url))

    def test_pages_advance_and_wrap_without_fetching_external_urls(self):
        rows = [{"id": "r1", "external_url": self.url},
                {"id": "r2", "external_url": "https://youtube.com/watch?v=x"}]
        with patch.object(self.gateway, "_rpc", side_effect=[rows, "job", []]) as rpc:
            self.gateway.discover()
            self.assertEqual(self.gateway.discovery_cursor, "r2")
            payload = rpc.call_args_list[1].args[1]
            self.assertEqual(payload["p_storage_path"], "a b.mp4")
            self.assertEqual(payload["p_resource_id"], "r1")
            self.gateway.discover()
            self.assertEqual(rpc.call_args.args[1]["p_after_id"], "r2")
            self.assertIsNone(self.gateway.discovery_cursor)

    def test_draft_target_and_page_failure_replay(self):
        row = {"id": "draft", "external_url": self.url}
        self.gateway.discovery_cursor = "cursor"
        with patch.object(self.gateway, "_rpc", side_effect=[[row], RuntimeError()]) as rpc:
            with self.assertRaises(RuntimeError):
                self.gateway.discover("draft")
            self.assertEqual(rpc.call_args_list[0].args[1]["p_draft_resource_id"], "draft")
            self.assertIsNone(rpc.call_args_list[0].args[1]["p_after_id"])
            self.assertTrue(rpc.call_args.args[1]["p_allow_draft"])
            self.assertEqual(self.gateway.discovery_cursor, "cursor")

    def test_continuous_success_immediate_idle_and_failures_wait(self):
        with patch("skilltrack_speech.worker.SupabaseGateway") as gateway, \
             patch("skilltrack_speech.worker.WhisperCppTranscriber"), \
             patch("skilltrack_speech.worker.process_one",
                   side_effect=["ready", None, RuntimeError(), KeyboardInterrupt()]) as process, \
             patch("skilltrack_speech.worker.time.sleep") as sleep:
            run = gateway.return_value
            with self.assertRaises(KeyboardInterrupt):
                run_forever(self.config)
            self.assertEqual(process.call_count, 4)
            self.assertEqual(run.discover.call_count, 4)
            self.assertEqual(sleep.call_count, 2)

    def test_once_discovers_and_processes_only_one_job(self):
        from skilltrack_speech.worker import main
        import sys
        from types import SimpleNamespace
        with patch.dict(sys.modules, {"dotenv": SimpleNamespace(load_dotenv=lambda: None)}), \
             patch.object(Config, "from_env", return_value=self.config), \
             patch("sys.argv", ["worker", "--once"]), \
             patch("skilltrack_speech.worker.SupabaseGateway") as gateway, \
             patch("skilltrack_speech.worker.WhisperCppTranscriber"), \
             patch("skilltrack_speech.worker.process_one", return_value="ready") as process:
            self.assertEqual(main(), 0)
            gateway.return_value.discover.assert_called_once_with(None)
            process.assert_called_once()

    def test_gateway_uses_transcript_primary_key_for_atomic_operations(self):
        row = {"id": "transcript-uuid", "claim_token": "token"}
        with patch.object(self.gateway, "_rpc", side_effect=[row, True, True, True]) as rpc:
            self.assertEqual(self.gateway.claim(900), row)
            self.assertTrue(self.gateway.renew(row["id"], "token", 900))
            self.assertTrue(self.gateway.complete(row["id"], "token", "text", "en", []))
            self.assertTrue(self.gateway.fail(row["id"], "token", "save_failed"))
            self.assertEqual([call.args[0] for call in rpc.call_args_list], [
                "claim_video_transcript", "renew_video_transcript",
                "complete_video_transcript", "fail_video_transcript",
            ])
            for call in rpc.call_args_list[1:]:
                self.assertEqual(call.args[1]["p_transcript_id"], row["id"])
                self.assertNotIn("p_job_id", call.args[1])
