"""Offline demonstration. The upload, Storage download, and model are simulated."""

from skilltrack_speech.worker import process_one
from tests.fakes import FakeGateway, FakeTranscriber


def main() -> None:
    gateway = FakeGateway()
    resource_id = "SAMPLE-RESOURCE-001"  # Clearly not a real marketplace ID.
    transcript_id = gateway.enqueue(resource_id, "SAMPLE-VIDEO-FILE-001", "sample-version-1")
    result = process_one(gateway, FakeTranscriber())
    saved = gateway.transcripts[transcript_id]
    print("SIMULATED upload/job source and SIMULATED transcription")
    print("Job path:", " -> ".join(gateway.history))
    print("Worker result:", result)
    print("Saved resource ID:", saved["resource_id"])
    print("Transcript:", saved["transcript_text"])


if __name__ == "__main__":
    main()

