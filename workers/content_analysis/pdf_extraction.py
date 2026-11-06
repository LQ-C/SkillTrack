"""Extract PDF text, using OCR only for pages with little selectable text.

The source PDF is opened read-only. OCR uses the Tesseract language data bundled
beside this module in ``Tesseract-OCR/tessdata``.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import sys


class PDFExtractionError(RuntimeError):
    """The PDF could not be opened or processed as a document."""


@dataclass(frozen=True)
class PageExtraction:
    number: int  # 1-based PDF page number
    text: str
    method: str  # "text", "ocr", or "empty"
    ocr_attempted: bool
    error: str | None = None


@dataclass(frozen=True)
class PDFExtractionResult:
    text: str
    pages: tuple[PageExtraction, ...]

    @property
    def ocr_pages(self) -> list[int]:
        """1-based pages that needed an OCR attempt, including blank pages."""
        return [page.number for page in self.pages if page.ocr_attempted]

    @property
    def empty_pages(self) -> list[int]:
        return [page.number for page in self.pages if page.method == "empty"]

    @property
    def errors(self) -> dict[int, str]:
        return {page.number: page.error for page in self.pages if page.error}


def _character_count(text: str) -> int:
    return sum(not character.isspace() for character in text)


def extract_pdf_text(
    pdf_path: str | Path,
    *,
    min_text_chars: int = 40,
    ocr_dpi: int = 200,
    tessdata_dir: str | Path | None = None,
) -> PDFExtractionResult:
    """Return combined text and page-level extraction details.

    Pages with fewer than ``min_text_chars`` non-whitespace characters are sent
    to English OCR. If OCR finds less text than direct extraction, the direct
    text is kept. Errors on individual pages are recorded in ``result.errors``;
    an unreadable PDF raises ``PDFExtractionError``.
    """
    if min_text_chars < 0:
        raise ValueError("min_text_chars must be zero or greater")
    if ocr_dpi < 72:
        raise ValueError("ocr_dpi must be at least 72")

    source = Path(pdf_path).expanduser()
    if not source.is_file():
        raise PDFExtractionError(f"PDF file not found: {source}")

    try:
        import pymupdf
    except ImportError as exc:
        raise PDFExtractionError("PyMuPDF is not installed in this Python environment") from exc

    tessdata = (
        Path(tessdata_dir).expanduser()
        if tessdata_dir is not None
        else Path(__file__).resolve().parent / "Tesseract-OCR" / "tessdata"
    )
    english_data = tessdata / "eng.traineddata"

    try:
        document = pymupdf.open(str(source))
    except Exception as exc:
        raise PDFExtractionError(f"Could not open PDF {source}: {exc}") from exc

    pages: list[PageExtraction] = []
    with document:
        if document.needs_pass:
            raise PDFExtractionError(f"PDF is password-protected: {source}")

        for index in range(document.page_count):
            number = index + 1
            errors: list[str] = []
            try:
                page = document.load_page(index)
            except Exception as exc:
                pages.append(PageExtraction(number, "", "empty", False, f"Page could not be loaded: {exc}"))
                continue

            direct_text = ""
            try:
                direct_text = page.get_text("text", sort=True).strip()
            except Exception as exc:
                errors.append(f"Direct text extraction failed: {exc}")

            chosen_text = direct_text
            method = "text" if direct_text else "empty"
            ocr_attempted = _character_count(direct_text) < min_text_chars

            if ocr_attempted:
                if not english_data.is_file():
                    errors.append(f"English OCR data not found: {english_data}")
                else:
                    try:
                        text_page = page.get_textpage_ocr(
                            language="eng",
                            dpi=ocr_dpi,
                            full=True,
                            tessdata=str(tessdata),
                        )
                        ocr_text = page.get_text("text", textpage=text_page, sort=True).strip()
                        if _character_count(ocr_text) > _character_count(direct_text):
                            chosen_text = ocr_text
                            method = "ocr"
                    except Exception as exc:
                        errors.append(f"OCR failed: {exc}")

            pages.append(
                PageExtraction(
                    number=number,
                    text=chosen_text,
                    method=method,
                    ocr_attempted=ocr_attempted,
                    error="; ".join(errors) or None,
                )
            )

    combined_text = "\n\n".join(page.text for page in pages if page.text)
    return PDFExtractionResult(combined_text, tuple(pages))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pdf", type=Path, help="PDF to extract")
    parser.add_argument("--min-text-chars", type=int, default=40)
    parser.add_argument("--ocr-dpi", type=int, default=200)
    parser.add_argument("--output", type=Path, help="Create a new UTF-8 .txt file with all extracted text")
    args = parser.parse_args(argv)

    try:
        result = extract_pdf_text(
            args.pdf,
            min_text_chars=args.min_text_chars,
            ocr_dpi=args.ocr_dpi,
        )
    except (PDFExtractionError, ValueError) as exc:
        print(f"PDF extraction error: {exc}", file=sys.stderr)
        return 1

    print(f"Pages: {len(result.pages)}")
    print("Methods: " + (", ".join(f"{page.number}={page.method}" for page in result.pages) or "none"))
    print(f"OCR attempted on pages: {result.ocr_pages or 'none'}")
    print(f"Empty pages: {result.empty_pages or 'none'}")
    for number, message in result.errors.items():
        print(f"Page {number} error: {message}", file=sys.stderr)

    if not result.text:
        print("No text was extracted from this PDF.", file=sys.stderr)
        return 2

    if args.output is not None:
        output = args.output.expanduser()
        if output.suffix.lower() != ".txt" or output.resolve() == args.pdf.resolve():
            print("Output must be a .txt file and cannot be the source PDF.", file=sys.stderr)
            return 1
        try:
            with output.open("x", encoding="utf-8") as stream:
                stream.write(result.text)
        except OSError as exc:
            print(f"Could not create output file {output}: {exc}", file=sys.stderr)
            return 1
        print(f"Saved extracted text to: {output}")
    else:
        excerpt = " ".join(result.text.split())[:240]
        print(f"Excerpt: {excerpt}{'...' if len(result.text) > 240 else ''}")

    return 1 if result.errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
