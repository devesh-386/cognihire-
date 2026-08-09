"""Tests for the resume pipeline stages.

Each stage is tested in isolation (that is the point of splitting them), plus
one orchestration test that fakes the store and gateway to prove the status
transitions and failure recording are right.
"""

from __future__ import annotations

import asyncio
import io

import pypdf
import pytest

from ai import claim_extraction
from deterministic import pdf_extraction, resume_parser
from pipeline import profile_builder, supabase_store


def _run(coro):
    return asyncio.run(coro)


# --- Stage 1: PDF extraction -----------------------------------------------


def _make_pdf(pages: list[str]) -> bytes:
    """Build a real PDF carrying the given text, so the test exercises pypdf
    rather than a mock of it.

    Hand-rolled rather than via a rendering library: the pipeline only needs a
    text layer to read, and this keeps the test suite free of a PDF-authoring
    dependency it would otherwise only use here. One text-showing operator per
    line, with a declared Helvetica resource so the text is genuinely
    extractable (a content stream naming an undeclared font parses fine and
    extracts nothing — which would silently make these tests meaningless).
    """
    objects: list[bytes] = []

    def add(body: bytes) -> int:
        objects.append(body)
        return len(objects)  # 1-indexed object numbers

    font_id = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")

    page_ids: list[int] = []
    content_ids: list[int] = []
    for text in pages:
        lines = text.splitlines() or [""]
        parts = [b"BT /F1 12 Tf 50 750 Td 14 TL"]
        for line in lines:
            escaped = line.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)")
            parts.append(f"({escaped}) Tj T*".encode("latin-1", "replace"))
        parts.append(b"ET")
        stream = b"\n".join(parts)
        content_ids.append(
            add(b"<< /Length %d >>\nstream\n%s\nendstream" % (len(stream), stream))
        )

    pages_id = len(objects) + len(pages) + 1
    for content_id in content_ids:
        page_ids.append(
            add(
                b"<< /Type /Page /Parent %d 0 R /MediaBox [0 0 612 792] "
                b"/Resources << /Font << /F1 %d 0 R >> >> /Contents %d 0 R >>"
                % (pages_id, font_id, content_id)
            )
        )

    kids = b" ".join(b"%d 0 R" % pid for pid in page_ids)
    add(b"<< /Type /Pages /Kids [%s] /Count %d >>" % (kids, len(page_ids)))
    catalog_id = add(b"<< /Type /Catalog /Pages %d 0 R >>" % pages_id)

    out = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for i, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % i + body + b"\nendobj\n"

    xref_pos = len(out)
    out += b"xref\n0 %d\n" % (len(objects) + 1)
    out += b"0000000000 65535 f \n"
    for off in offsets[1:]:
        out += b"%010d 00000 n \n" % off
    out += b"trailer\n<< /Size %d /Root %d 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (
        len(objects) + 1,
        catalog_id,
        xref_pos,
    )
    return bytes(out)


def test_empty_file_is_reported_not_silently_empty():
    result = pdf_extraction.extract_text(b"")
    assert not result.ok
    assert "empty" in result.error


def test_unreadable_bytes_are_reported():
    result = pdf_extraction.extract_text(b"this is definitely not a pdf")
    assert not result.ok
    assert result.text == ""
    assert result.error


def test_scanned_pdf_is_reported_as_needing_ocr():
    # A valid PDF with no text layer — exactly the scanned-resume case.
    writer = pypdf.PdfWriter()
    writer.add_blank_page(width=612, height=792)
    buf = io.BytesIO()
    writer.write(buf)

    result = pdf_extraction.extract_text(buf.getvalue())

    assert not result.ok
    assert "OCR" in result.error


def test_text_pdf_extracts_successfully():
    body = "Built and shipped a React dashboard used by 200+ staff. " * 4
    result = pdf_extraction.extract_text(_make_pdf([body]))

    assert result.ok, result.error
    # A text PDF never touches the OCR path — nothing to disclose.
    assert result.used_ocr is False


def test_scanned_pdf_falls_back_to_ocr_and_reports_when_unavailable(monkeypatch):
    """Same scanned-page fixture as the OCR-needed test above, but asserts
    the specific new behaviour: the fallback is attempted (not skipped), and
    when the OCR engine itself can't run (as in this test environment, which
    has no tesseract/poppler installed), that reason is surfaced rather than
    a generic message."""
    writer = pypdf.PdfWriter()
    writer.add_blank_page(width=612, height=792)
    buf = io.BytesIO()
    writer.write(buf)

    result = pdf_extraction.extract_text(buf.getvalue())

    assert not result.ok
    assert result.used_ocr is False
    assert "OCR" in result.error


def test_ocr_recovers_text_when_selectable_layer_is_too_thin(monkeypatch):
    """Exercises the success path with a stub OCR engine, since the real one
    needs tesseract/poppler system binaries this test environment doesn't
    have installed."""
    import deterministic.pdf_extraction as pdf_extraction_module

    def fake_try_ocr(pdf_bytes):
        return "Built and shipped a React dashboard used by 200+ staff. " * 4, None

    monkeypatch.setattr(pdf_extraction_module, "_try_ocr", fake_try_ocr)

    writer = pypdf.PdfWriter()
    writer.add_blank_page(width=612, height=792)
    buf = io.BytesIO()
    writer.write(buf)

    result = pdf_extraction.extract_text(buf.getvalue())

    assert result.ok, result.error
    assert result.used_ocr is True
    assert "React dashboard" in result.text
    assert "React dashboard" in result.text
    assert result.page_count == 1


# --- Stage 2: resume parser -------------------------------------------------


RESUME_TEXT = """\
Devesh S
deveshsv.386@gmail.com

Skills
Python, Flutter, Machine Learning, PostgreSQL

Projects
- CogniHire — verified-claim interview intelligence
- ViStream — video analysis pipeline

Experience
- Led a team of 4 engineers.

Education
- B.Tech Computer Science
"""


def test_parser_extracts_sections():
    parsed = resume_parser.parse(RESUME_TEXT)

    assert parsed.name == "Devesh S"
    assert parsed.email == "deveshsv.386@gmail.com"
    assert "Python" in parsed.skills
    assert "Machine Learning" in parsed.skills
    assert any("CogniHire" in p for p in parsed.projects)
    assert any("Led a team" in e for e in parsed.experience)
    assert any("B.Tech" in e for e in parsed.education)


def test_parser_never_raises_on_unstructured_text():
    parsed = resume_parser.parse("just some words with no sections at all")
    assert parsed.skills == []
    assert parsed.projects == []


def test_parser_deduplicates_skills_case_insensitively():
    parsed = resume_parser.parse("Skills\nPython, python, PYTHON, Flutter")
    lowered = [s.lower() for s in parsed.skills]
    assert lowered.count("python") == 1


def test_parser_does_not_invent_a_name_from_contact_lines():
    parsed = resume_parser.parse("someone@example.com\n+1 5551234567\n\nSkills\nGo")
    assert parsed.name is None


# --- Stage 4: orchestration -------------------------------------------------


class _FakeStore:
    """Records every upsert so the test can assert the status sequence."""

    def __init__(self, candidate: dict | None, pdf: bytes):
        self._candidate = candidate
        self._pdf = pdf
        self.writes: list[dict] = []

    async def fetch_candidate(self, candidate_id):
        return self._candidate

    async def download_resume(self, path):
        return self._pdf

    async def upsert_profile(self, candidate_id, org_id, fields):
        self.writes.append(fields)

    @property
    def statuses(self):
        return [w["processing_status"] for w in self.writes if "processing_status" in w]


def _patch_pipeline(monkeypatch, store, extraction_result):
    monkeypatch.setattr(profile_builder.supabase_store, "fetch_candidate", store.fetch_candidate)
    monkeypatch.setattr(profile_builder.supabase_store, "download_resume", store.download_resume)
    monkeypatch.setattr(profile_builder.supabase_store, "upsert_profile", store.upsert_profile)

    async def fake_extract(text, source, provider=None):
        return extraction_result

    monkeypatch.setattr(profile_builder.claim_extraction, "extract_claims", fake_extract)


CANDIDATE = {
    "id": "cand-1",
    "organization_id": "org-1",
    "name": "Devesh S",
    "email": "d@example.com",
    "resume_path": "org-1/resume.pdf",
}


def test_happy_path_walks_the_full_status_sequence(monkeypatch):
    pdf = _make_pdf([RESUME_TEXT + " Led a team of 4 engineers. " * 3])
    store = _FakeStore(CANDIDATE, pdf)
    _patch_pipeline(
        monkeypatch,
        store,
        claim_extraction.ClaimExtraction(
            claims=[claim_extraction.Claim(id="c1", text="Led a team of 4 engineers.", source="resume")],
            kind="hosted_llm",
        ),
    )

    result = _run(profile_builder.process_candidate_resume("cand-1"))

    assert store.statuses == [
        "TEXT_EXTRACTED",
        "STRUCTURED",
        "CLAIMS_READY",
        "READY_FOR_INTERVIEW",
    ]
    assert result["status"] == "READY_FOR_INTERVIEW"
    assert result["claim_count"] == 1


def test_a_resume_yielding_nothing_grounded_is_not_marked_ready(monkeypatch):
    """Regression. The pipeline used to mark every candidate whose text
    extracted READY_FOR_INTERVIEW, even with zero claims and zero grounded
    facts. READY_FOR_INTERVIEW is what fires the auto-invite, so that emailed
    the candidate a code for an interview whose plan has no topics — one that
    opens, immediately completes, and yields a report reading "complete" with
    not a single question asked. FAILED surfaces it in the HR dashboard's
    "Needs attention" list instead."""
    # Real extractable text, so the run genuinely reaches the end of the
    # pipeline — a blank PDF would fail at text extraction and pass this test
    # without ever exercising the check it exists for.
    pdf = _make_pdf([RESUME_TEXT])
    store = _FakeStore(CANDIDATE, pdf)
    _patch_pipeline(
        monkeypatch, store,
        claim_extraction.ClaimExtraction(claims=[], kind="hosted_llm"),
    )

    profile_cls = type(_run(profile_builder.resume_understanding.understand("")))

    async def no_facts(text, provider_override=None):
        return profile_cls(kind="hosted_llm")

    monkeypatch.setattr(profile_builder.resume_understanding, "understand", no_facts)

    result = _run(profile_builder.process_candidate_resume("cand-1"))

    # Got all the way through extraction and structuring before being refused.
    assert store.statuses[:3] == ["TEXT_EXTRACTED", "STRUCTURED", "CLAIMS_READY"]
    assert result["status"] == "FAILED"
    assert "READY_FOR_INTERVIEW" not in store.statuses
    assert store.statuses[-1] == "FAILED"


def test_scanned_pdf_records_failed_and_stops(monkeypatch):
    writer = pypdf.PdfWriter()
    writer.add_blank_page(width=612, height=792)
    buf = io.BytesIO()
    writer.write(buf)

    store = _FakeStore(CANDIDATE, buf.getvalue())
    _patch_pipeline(monkeypatch, store, claim_extraction.ClaimExtraction(claims=[], kind="hosted_llm"))

    result = _run(profile_builder.process_candidate_resume("cand-1"))

    assert store.statuses == ["FAILED"]
    assert result["status"] == "FAILED"
    assert "OCR" in result["error"]


def test_candidate_without_resume_fails_cleanly(monkeypatch):
    store = _FakeStore({**CANDIDATE, "resume_path": None}, b"")
    _patch_pipeline(monkeypatch, store, claim_extraction.ClaimExtraction(claims=[], kind="hosted_llm"))

    result = _run(profile_builder.process_candidate_resume("cand-1"))

    assert result["status"] == "FAILED"
    assert "no uploaded resume" in result["error"]


def test_missing_candidate_raises_rather_than_reporting_success(monkeypatch):
    store = _FakeStore(None, b"")
    _patch_pipeline(monkeypatch, store, claim_extraction.ClaimExtraction(claims=[], kind="hosted_llm"))

    with pytest.raises(supabase_store.SupabaseError):
        _run(profile_builder.process_candidate_resume("nope"))


def test_degraded_extraction_still_reaches_ready(monkeypatch):
    """A provider outage weakens the claims but must not block the interview."""
    pdf = _make_pdf([RESUME_TEXT + " Led a team of 4 engineers. " * 3])
    store = _FakeStore(CANDIDATE, pdf)
    _patch_pipeline(
        monkeypatch,
        store,
        claim_extraction.ClaimExtraction(
            claims=[claim_extraction.Claim(id="c1", text="Led a team of 4 engineers.", source="resume")],
            kind="heuristic_rule",
            degraded_reason="the hosted model did not answer in time",
        ),
    )

    result = _run(profile_builder.process_candidate_resume("cand-1"))

    assert store.statuses[-1] == "READY_FOR_INTERVIEW"
    assert result["degraded_reason"] == "the hosted model did not answer in time"
    claims_write = [w for w in store.writes if "claim_extraction_kind" in w][0]
    assert claims_write["claim_extraction_kind"] == "heuristic_rule"


def test_interview_context_is_never_persisted(monkeypatch):
    """Context is assembled fresh at interview start; storing it here would
    serve a stale one the first time HR changes a setting."""
    pdf = _make_pdf([RESUME_TEXT + " Led a team of 4 engineers. " * 3])
    store = _FakeStore(CANDIDATE, pdf)
    _patch_pipeline(monkeypatch, store, claim_extraction.ClaimExtraction(claims=[], kind="hosted_llm"))

    _run(profile_builder.process_candidate_resume("cand-1"))

    for write in store.writes:
        assert "interview_context" not in write
