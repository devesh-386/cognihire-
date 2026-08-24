"""`_safe_download_filename` — the guard between an uploaded résumé's name
and a Content-Disposition header.

`/candidates/{id}/resume` echoes the last segment of `resume_path` back in
`Content-Disposition: inline; filename="..."`. That segment is whatever the
candidate's browser called the file, carried through the apply/intake
ingestion paths into the storage key. Unescaped inside a quoted header
parameter, a double quote ends the string early and a newline splits the
header.

The upload side rejects these names outright now (infra/apply-webhook), so
this is the second of two independent checks — and the only one that covers
résumés already sitting in the bucket from before that validation existed.
"""

from __future__ import annotations

import pytest

from main import _safe_download_filename


def test_ordinary_filename_survives_unchanged():
    assert _safe_download_filename("org-1/cand-2-Jane_Doe-CV.pdf") == "cand-2-Jane_Doe-CV.pdf"


def test_only_the_last_path_segment_is_used():
    assert _safe_download_filename("org-1/nested/dir/resume.pdf") == "resume.pdf"


@pytest.mark.parametrize(
    "hostile",
    [
        'org-1/eviL".pdf',                      # closes the quoted parameter early
        "org-1/evil\r\nX-Injected: yes.pdf",    # header splitting
        "org-1/evil\nSet-Cookie: a=b.pdf",      # header splitting, LF only
        'org-1/a"; filename="b.pdf',            # swaps in a second filename parameter
    ],
)
def test_quotes_and_newlines_cannot_escape_the_header(hostile):
    """The whole point: whatever comes out must be safe to drop between two
    double quotes without changing the header's structure."""
    result = _safe_download_filename(hostile)
    assert '"' not in result
    assert "\r" not in result and "\n" not in result
    assert ";" not in result


def test_leading_dots_are_dropped():
    """`.htaccess`-style names, and anything that would render as a hidden
    or relative-looking file when saved."""
    assert not _safe_download_filename("org-1/...hidden.pdf").startswith(".")


def test_a_name_that_sanitizes_to_nothing_falls_back():
    """`filename=""` is a malformed header, so an empty result is not an
    acceptable outcome of stripping."""
    assert _safe_download_filename("org-1/") == "resume.pdf"
    assert _safe_download_filename("org-1/...") == "resume.pdf"


def test_length_is_capped():
    result = _safe_download_filename("org-1/" + "a" * 500 + ".pdf")
    assert len(result) <= 120


def test_non_ascii_is_replaced_not_passed_through():
    """Latin-1-unencodable characters raise when Starlette writes the
    header, so a résumé named in Devanagari or Chinese must not reach it —
    a 500 on download is a worse outcome for that candidate than an
    underscored filename."""
    result = _safe_download_filename("org-1/简历-résumé.pdf")
    result.encode("latin-1")  # must not raise
    assert result.endswith(".pdf")
