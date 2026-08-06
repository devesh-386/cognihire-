"""Stage 1 — PDF to text. Nothing else.

This stage knows about PDFs and nothing about resumes, claims, or models. It
is the only place in the backend that touches a PDF binary; every later stage
reads text. That boundary is what lets an ML model be added to the pipeline
without ever teaching it to parse a document.

Scanned/image-only PDFs are a *reported* failure, not a silent empty string —
`lib/features/resume/resume_text_extraction.dart` made the same call on the
client, and the reasoning holds here: returning "" for a resume that has text
we simply could not read would present as "this candidate wrote nothing".
"""

from __future__ import annotations

from dataclasses import dataclass

import pypdf


@dataclass
class TextExtraction:
    text: str
    page_count: int
    ok: bool
    error: str | None = None


# Below this, a PDF that "parsed fine" is almost certainly a scan: the only
# text pypdf found is stray artefacts. Chosen to be forgiving — a genuinely
# sparse one-page resume still clears it.
_MIN_MEANINGFUL_CHARS = 100


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

    if len(text) < _MIN_MEANINGFUL_CHARS:
        return TextExtraction(
            text=text,
            page_count=len(pages),
            ok=False,
            error=(
                "almost no selectable text was found — this is likely a scanned "
                "or image-only PDF, which needs OCR this build does not do"
            ),
        )

    return TextExtraction(text=text, page_count=len(pages), ok=True)
