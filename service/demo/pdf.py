"""A minimal, genuinely-extractable single-page PDF builder for synthetic
demo resumes — same construction `test_end_to_end.py` uses for the RC1
acceptance test, kept here as the one real (non-test) copy so `demo/seed.py`
doesn't reach into a test module for it."""

from __future__ import annotations


def text_to_pdf(text: str) -> bytes:
    lines = text.splitlines()
    parts = [b"BT /F1 12 Tf 50 750 Td 14 TL"]
    for line in lines:
        escaped = line.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)")
        parts.append(f"({escaped}) Tj T*".encode("latin-1", "replace"))
    parts.append(b"ET")
    stream = b"\n".join(parts)

    objects = [
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        b"<< /Length %d >>\nstream\n%s\nendstream" % (len(stream), stream),
        b"<< /Type /Page /Parent 4 0 R /Resources << /Font << /F1 1 0 R >> >> "
        b"/MediaBox [0 0 612 792] /Contents 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Catalog /Pages 4 0 R >>",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for i, obj in enumerate(objects, start=1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n".encode() + obj + b"\nendobj\n"
    xref_offset = len(out)
    out += f"xref\n0 {len(objects) + 1}\n".encode()
    out += b"0000000000 65535 f \n"
    for off in offsets[1:]:
        out += f"{off:010d} 00000 n \n".encode()
    out += (
        f"trailer\n<< /Size {len(objects) + 1} /Root 5 0 R >>\n"
        f"startxref\n{xref_offset}\n%%EOF"
    ).encode()
    return bytes(out)
