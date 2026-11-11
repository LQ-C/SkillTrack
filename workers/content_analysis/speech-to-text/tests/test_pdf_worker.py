import tempfile
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from skilltrack_speech import pdf_adapter
from skilltrack_speech.worker import process_one
from skilltrack_speech.config import Config
from skilltrack_speech.supabase_gateway import SupabaseGateway
from tests.fakes import FakeGateway

class PDFWorkerTests(unittest.TestCase):
    def test_discovery_requires_reading_pdf_and_verified_private_bucket(self):
        gateway = SupabaseGateway(Config("https://example.supabase.co", "fake", video_bucket="videos"))
        root = "https://example.supabase.co/storage/v1/object/authenticated/marketplace-documents/"
        rows = [{"id": "pdf", "kind": "Reading", "external_url": root + "lesson.pdf"},
                {"id": "other", "kind": "Reading", "external_url": root + "lesson.docx"},
                {"id": "external", "kind": "Reading", "external_url": "https://external.test/lesson.pdf"}]
        with patch.object(gateway, "_rpc", side_effect=[rows, "id"]) as rpc:
            gateway.discover()
            self.assertEqual(rpc.call_count, 2)
            self.assertEqual(rpc.call_args.args[0], "enqueue_discovered_extraction")
            self.assertEqual(rpc.call_args.args[1]["p_storage_bucket"], "marketplace-documents")
        self.assertIsNone(gateway._storage_path(root + 'lesson.pdf?token=private', gateway.config.pdf_bucket))

    def test_real_text_pdf_and_invalid_encrypted_files(self):
        try:
            import pymupdf
        except ImportError:
            self.skipTest("PyMuPDF unavailable")
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "source.pdf"
            doc = pymupdf.open(); page = doc.new_page()
            page.insert_text((72,72), "Flutter widgets compose mobile interfaces with readable layouts and clear state.")
            doc.save(path); doc.close()
            text, language, segments = pdf_adapter.extract_bounded(path)
            self.assertIn("Flutter widgets", text); self.assertIsNone(language); self.assertEqual(segments, [])
            doc = pymupdf.open(path)
            encrypted = Path(temp) / "encrypted.pdf"
            doc.save(encrypted, encryption=pymupdf.PDF_ENCRYPT_AES_256, owner_pw="test-owner", user_pw="test-user")
            doc.close()
            with self.assertRaisesRegex(pdf_adapter.PDFWorkError, 'pdf_encrypted'): pdf_adapter.extract(encrypted)
            path.write_bytes(b'not a PDF')
            with self.assertRaisesRegex(pdf_adapter.PDFWorkError, 'pdf_invalid'): pdf_adapter.extract(path)

    def test_pdf_processing_persists_same_identity_and_cleans_temp(self):
        gateway = FakeGateway()
        row = gateway.enqueue("resource", "file", "v1", "marketplace-documents", "lesson.pdf")
        gateway.transcripts[row]["extraction_type"] = "pdf_text"
        transcriber = SimpleNamespace(transcribe=lambda _: self.fail("PDF sent to Whisper"))
        with patch("skilltrack_speech.worker.extract_pdf", return_value=("PDF text", None, [])):
            self.assertEqual(process_one(gateway, transcriber), "ready")
        self.assertEqual(gateway.transcripts[row]["transcript_text"], "PDF text")
        self.assertFalse(gateway.downloaded_path.exists())

    def test_pdf_failure_is_bounded_and_does_not_persist_partial_text(self):
        gateway = FakeGateway()
        row = gateway.enqueue("resource", "file", "v1", "marketplace-documents", "lesson.pdf")
        gateway.transcripts[row]["extraction_type"] = "pdf_text"
        with patch("skilltrack_speech.worker.extract_pdf", side_effect=pdf_adapter.PDFWorkError("pdf_empty")):
            for _ in range(3):
                self.assertEqual(process_one(gateway, None), "pdf_empty")
                gateway.now += 3600
        self.assertEqual(gateway.transcripts[row]["status"], "failed")
        self.assertFalse(gateway.downloaded_path.exists())

    def test_scanned_pdf_ocr_path_and_errors_without_real_ocr(self):
        # Exercise the real extractor's OCR branch with fake pages; no OCR engine claim.
        page = SimpleNamespace(get_text=lambda mode, **kw: "Scanned Flutter tutorial" if 'textpage' in kw else '',
                               get_textpage_ocr=lambda **kw: object())
        class Document:
            needs_pass=False; page_count=1
            def __enter__(self): return self
            def __exit__(self,*args): pass
            def load_page(self,index): return page
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'scan.pdf';path.touch();(Path(temp)/'eng.traineddata').touch()
            with patch.dict('sys.modules', {'pymupdf': SimpleNamespace(open=lambda _: Document())}), patch.dict('os.environ',{'TESSDATA_PREFIX':temp}):
                self.assertEqual(pdf_adapter.extract(path)[0], 'Scanned Flutter tutorial')
                page.get_textpage_ocr=lambda **kw: (_ for _ in ()).throw(RuntimeError('unavailable'))
                with self.assertRaisesRegex(pdf_adapter.PDFWorkError,'pdf_ocr_failed'):pdf_adapter.extract(path)
            result=SimpleNamespace(text=' ',errors={})
            with patch.object(pdf_adapter._module,'extract_pdf_text',return_value=result):
                with self.assertRaisesRegex(pdf_adapter.PDFWorkError,'pdf_empty'):pdf_adapter.extract(path)
