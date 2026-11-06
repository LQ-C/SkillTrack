from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import unittest

from skilltrack_speech.worker import process_one
from tests.fakes import FakeGateway, FakeTranscriber


class WorkerTests(unittest.TestCase):
    def test_resource_id_segments_and_cleanup(self):
        gateway = FakeGateway()
        job_id = gateway.enqueue("SAMPLE-RESOURCE-001", "SAMPLE-FILE-001", "version-1")
        self.assertEqual(process_one(gateway, FakeTranscriber()), "ready")
        transcript = gateway.transcripts[job_id]
        self.assertEqual(transcript["resource_id"], "SAMPLE-RESOURCE-001")
        self.assertEqual(transcript["language"], "en")
        self.assertEqual(transcript["segments"][0]["start"], 0.0)
        self.assertEqual(gateway.history, ["pending", "processing", "ready"])
        self.assertFalse(gateway.downloaded_path.exists())

    def test_duplicate_enqueue_and_completion_retry(self):
        gateway = FakeGateway()
        job_id = gateway.enqueue("r1", "f1", "v1")
        self.assertEqual(gateway.enqueue("r1", "f1", "v1"), job_id)
        with self.assertRaises(ValueError):
            gateway.enqueue("r1", "f1", "v1", path="another.mp4")
        claim = gateway.claim(900)
        self.assertTrue(gateway.complete(job_id, claim["claim_token"], "hello", "en", []))
        self.assertTrue(gateway.complete(job_id, claim["claim_token"], "hello", "en", []))
        self.assertEqual(len(gateway.transcripts), 1)
        self.assertIsNone(gateway.claim(900))

    def test_stale_worker_cannot_finish_reassigned_job(self):
        gateway = FakeGateway()
        job_id = gateway.enqueue("r1", "f1", "v1")
        old = gateway.claim(60)
        gateway.advance(61)
        new = gateway.claim(60)
        self.assertNotEqual(old["claim_token"], new["claim_token"])
        self.assertFalse(gateway.complete(job_id, old["claim_token"], "stale", "en", []))
        self.assertFalse(gateway.renew(job_id, old["claim_token"], 60))
        self.assertTrue(gateway.complete(job_id, new["claim_token"], "fresh", "en", []))
        self.assertEqual(gateway.transcripts[job_id]["transcript_text"], "fresh")

    def test_failed_download_retries_and_cleans_temp(self):
        gateway = FakeGateway(max_attempts=2)
        gateway.enqueue("r1", "f1", "v1")
        gateway.download_error = True
        self.assertEqual(process_one(gateway, FakeTranscriber()), "download_failed")
        self.assertFalse(gateway.downloaded_path.exists())
        self.assertIsNone(gateway.claim(900))  # backoff applies
        gateway.advance(120)
        self.assertEqual(process_one(gateway, FakeTranscriber()), "download_failed")
        job = next(iter(gateway.jobs.values()))
        self.assertEqual(job["status"], "failed")
        self.assertEqual(job["attempt_count"], 2)

    def test_model_failure_retries_with_no_transcript(self):
        gateway = FakeGateway()
        gateway.enqueue("r1", "f1", "v1")
        self.assertEqual(process_one(gateway, FakeTranscriber(fail=True)),
                         "transcription_failed")
        self.assertEqual(gateway.transcripts, {})
        self.assertFalse(gateway.downloaded_path.exists())

    def test_concurrent_claims_in_fake_are_exclusive(self):
        gateway = FakeGateway()
        gateway.enqueue("r1", "f1", "v1")
        with ThreadPoolExecutor(max_workers=2) as pool:
            claims = list(pool.map(gateway.claim, [900, 900]))
        self.assertEqual(sum(item is not None for item in claims), 1)


if __name__ == "__main__":
    unittest.main()

