"""Stage 1 — PDF to text. Nothing else.

This stage knows about PDFs and nothing about resumes, claims, or models. It
is the only place in the backend that touches a PDF binary; every later stage
reads text. That boundary is what lets an ML model be added to the pipeline
without ever teaching it to parse a document.

## Scanned/image-only PDFs

A resume with no selectable text is common — a phone-scanned page, a PDF
some scanner app produced from a photo, an export that flattened every page
to an image. Refusing all of these outright would silently exclude a real
chunk of candidates from the pipeline for reasons that have nothing to do
with them as a candidate. So this stage falls back to OCR (`pytesseract`
over `pdf2image`-rendered pages) when pypdf's selectable-text pass comes back
too thin, rather than reporting failure on the first try.

OCR is still allowed to fail honestly — a genuinely blank page, a corrupt
scan, missing system dependencies (`tesseract`/`poppler`, not installed) —
and that failure is a *reported* fact, not a silent empty string, same
reasoning `lib/features/resume/resume_text_extraction.dart` applies on the
client: returning "" for a resume we simply could not read would present as
"this candidate wrote nothing".
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

import pypdf

logger = logging.getLogger("cognihire.deterministic.pdf_extraction")


@dataclass
class TextExtraction:
    text: str
    page_count: int
    ok: bool
    error: str | None = None
    # True only when the selectable-text pass came back too thin and OCR
    # produced the text instead — surfaced so a caller (or a future report)
    # can note the source is a lower-fidelity read of a scanned document,
    # not a claim the candidate typed.
    used_ocr: bool = False


# Below this, a PDF that "parsed fine" is almost certainly a scan: the only
# text pypdf found is stray artefacts. Chosen to be forgiving — a genuinely
# sparse one-page resume still clears it.
_MIN_MEANINGFUL_CHARS = 100

# A resume rarely runs past this many pages; capping bounds OCR's cost (each
# page is a full image render + a Tesseract pass) against a malformed or
# absurdly long upload rather than trusting the file to behave.
_MAX_OCR_PAGES = 10


def _try_ocr(pdf_bytes: bytes) -> tuple[str, str | None]:
    """Best-effort OCR fallback. Returns (text, error) — text is "" and error
    is set on any failure, including the system dependencies being absent,
    since a build without tesseract/poppler installed must degrade to the
    same honest "could not read this" outcome rather than crash the request.
    """
    try:
        import pytesseract
        from pdf2image import convert_from_bytes
    except ImportError as exc:
        return "", f"OCR is unavailable in this build ({exc})"

    try:
        images = convert_from_bytes(pdf_bytes, dpi=200)
    except Exception as exc:  # noqa: BLE001 — report any render failure verbatim
        return "", f"the PDF could not be rendered for OCR ({exc})"

    if len(images) > _MAX_OCR_PAGES:
        return "", (
            f"the document has {len(images)} pages, more than the "
            f"{_MAX_OCR_PAGES}-page OCR limit"
        )

    try:
        pages = [pytesseract.image_to_string(image) for image in images]
    except Exception as exc:  # noqa: BLE001 — report any OCR engine failure verbatim
        return "", f"OCR failed ({exc})"

    return "\n".join(pages).strip(), None


def extract_text(pdf_bytes: bytes) -> TextExtraction:
    """Never raises. A failure is a reported fact, not an exception, because
    the caller's job is to record it on the profile and move on."""
    if not pdf_bytes:
        return TextExtraction(text="", page_count=0, ok=False, error="the file was empty")

    try:
        import io

        reader = pypdf.PdfReader(io.BytesIO(pdf_bytes))
        pages = [page.extract_text() or "" for page in reader.pages]
    except Exception as exc:  # noqa: BLE001 — report any parse failure verbatim
        return TextExtraction(
            text="", page_count=0, ok=False, error=f"the PDF could not be read ({exc})"
        )

    text = "\n".join(pages).strip()

    if len(text) >= _MIN_MEANINGFUL_CHARS:
        return TextExtraction(text=text, page_count=len(pages), ok=True)

    ocr_text, ocr_error = _try_ocr(pdf_bytes)
    if ocr_error:
        logger.info("OCR fallback did not produce text: %s", ocr_error)
    if len(ocr_text) >= _MIN_MEANINGFUL_CHARS:
        return TextExtraction(text=ocr_text, page_count=len(pages), ok=True, used_ocr=True)

    return TextExtraction(
        text=text,
        page_count=len(pages),
        ok=False,
        error=(
            "almost no selectable text was found and OCR could not recover "
            "enough either — this document may be blank, corrupt, or too low "
            "quality to read" + (f" ({ocr_error})" if ocr_error else "")
        ),
    )
