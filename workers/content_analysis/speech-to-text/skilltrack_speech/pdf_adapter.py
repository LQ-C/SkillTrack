"""Reuse the existing PDF/OCR extractor without exposing document text in logs."""
from __future__ import annotations
import importlib.util
import os
from pathlib import Path
import sys

# The standalone extractor stays in its existing location; import by path so
# worker commands work from any working directory, without modifying sys.path.
_path = Path(__file__).resolve().parents[2] / "pdf_extraction.py"
_spec = importlib.util.spec_from_file_location("skilltrack_pdf_extraction", _path)
assert _spec and _spec.loader
_module = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = _module
_spec.loader.exec_module(_module)

class PDFWorkError(RuntimeError):
    def __init__(self, code: str):
        self.code = code
        super().__init__(code)

def extract(path: Path):
    try:
        result = _module.extract_pdf_text(path, tessdata_dir=os.getenv("TESSDATA_PREFIX") or None)
    except _module.PDFExtractionError as exc:
        code = "pdf_encrypted" if "password-protected" in str(exc) else "pdf_invalid"
        raise PDFWorkError(code) from None
    except Exception:
        raise PDFWorkError("pdf_extraction_failed") from None
    if result.errors:
        raise PDFWorkError("pdf_ocr_failed")
    if not result.text.strip():
        raise PDFWorkError("pdf_empty")
    return result.text, None, []


def extract_bounded(path: Path):
    """Isolate native OCR with a timeout; temporary text stays beside the input."""
    import subprocess
    output = path.with_suffix(".extracted.txt")
    codes = ["pdf_invalid", "pdf_encrypted", "pdf_empty", "pdf_ocr_failed", "pdf_extraction_failed"]
    try:
        timeout = int(os.getenv("PDF_EXTRACT_TIMEOUT_SECONDS", "600"))
        if not 1 <= timeout <= 7200:
            raise ValueError("Invalid PDF timeout")
        result = subprocess.run([sys.executable, str(Path(__file__).resolve()), str(path), str(output)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0), check=False)
        if 10 <= result.returncode < 10 + len(codes):
            raise PDFWorkError(codes[result.returncode - 10])
        if result.returncode != 0:
            raise PDFWorkError("pdf_extraction_failed")
        text = output.read_text(encoding="utf-8")
        if not text.strip(): raise PDFWorkError("pdf_empty")
        return text, None, []
    except PDFWorkError:
        raise
    except Exception:
        raise PDFWorkError("pdf_extraction_failed") from None
    finally:
        output.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        text, _, _ = extract(Path(sys.argv[1]))
        Path(sys.argv[2]).write_text(text, encoding="utf-8")
    except PDFWorkError as error:
        codes = ["pdf_invalid", "pdf_encrypted", "pdf_empty", "pdf_ocr_failed", "pdf_extraction_failed"]
        raise SystemExit(10 + codes.index(error.code))
