"""Fallback resume parsing — section-and-pattern matching, no model.

**This is not the primary path.** Resume understanding is an AI stage
(`ai/resume_understanding.py`); this module is what runs when the provider is
unreachable, and what supplies deterministically-matched fields (email) that
should never be trusted to a model.

Keeping it is not hedging. A degraded profile built from headings and line
shapes is weaker than a model's reading — it knows "Skills" is a heading but
not that a project bullet describes ownership — yet it is honest, it is
instant, and it means a vendor outage costs quality rather than costing the
candidate their interview. `understanding_kind` on the profile records which
one actually ran, so nothing downstream mistakes one for the other.

Every value here is copied from the source text, never generated.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field, asdict

# Section headings a resume actually uses. Matched case-insensitively against
# a whole line, so "SKILLS" and "Technical Skills" both land.
_SECTION_PATTERNS: dict[str, re.Pattern] = {
    "skills": re.compile(r"^\s*(technical\s+)?skills?\b.*$", re.I),
    "projects": re.compile(r"^\s*(personal\s+|key\s+)?projects?\b.*$", re.I),
    "experience": re.compile(
        r"^\s*(work\s+|professional\s+)?experience\b.*$|^\s*employment\b.*$", re.I
    ),
    "education": re.compile(r"^\s*education\b.*$|^\s*academics?\b.*$", re.I),
    "certifications": re.compile(r"^\s*certifications?\b.*$|^\s*licenses?\b.*$", re.I),
}

_BULLET = re.compile(r"^[\-\*•·▪‣◦]\s*")

# Skills lines are usually comma/pipe/slash separated lists.
_SKILL_SPLIT = re.compile(r"[,|/;]|\s{2,}")


@dataclass
class StructuredResume:
    name: str | None = None
    email: str | None = None
    skills: list[str] = field(default_factory=list)
    projects: list[str] = field(default_factory=list)
    experience: list[str] = field(default_factory=list)
    education: list[str] = field(default_factory=list)
    certifications: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return asdict(self)


_EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.]+")


def _sections(lines: list[str]) -> dict[str, list[str]]:
    """Split lines into named sections. Anything before the first recognised
    heading is the header block (name, contact details)."""
    out: dict[str, list[str]] = {"_header": []}
    current = "_header"

    for line in lines:
        matched = None
        for name, pattern in _SECTION_PATTERNS.items():
            if pattern.match(line) and len(line.strip()) < 60:
                matched = name
                break
        if matched:
            current = matched
            out.setdefault(current, [])
            continue
        out.setdefault(current, []).append(line)

    return out


def _clean_entries(lines: list[str]) -> list[str]:
    entries = []
    for line in lines:
        cleaned = _BULLET.sub("", line).strip()
        if len(cleaned) >= 3:
            entries.append(cleaned)
    return entries


def parse(resume_text: str) -> StructuredResume:
    """Never raises. An unparseable resume yields an empty structure, which
    the pipeline records rather than treating as an error — a resume with no
    recognisable sections is still a resume."""
    lines = resume_text.splitlines()
    sections = _sections(lines)

    header = [ln.strip() for ln in sections.get("_header", []) if ln.strip()]

    email_match = _EMAIL.search(resume_text)

    # The name is conventionally the first non-empty header line that is not a
    # contact detail. A guess, and labelled as one — nothing downstream should
    # treat it as verified identity (that is the face service's job).
    name = None
    for line in header:
        if _EMAIL.search(line) or re.search(r"\d{5,}", line):
            continue
        if 2 <= len(line) <= 60:
            name = line
            break

    skills: list[str] = []
    for line in sections.get("skills", []):
        cleaned = _BULLET.sub("", line).strip()
        if not cleaned:
            continue
        for token in _SKILL_SPLIT.split(cleaned):
            token = token.strip(" .:-")
            if 1 < len(token) <= 40:
                if token.lower() not in {s.lower() for s in skills}:
                    skills.append(token)

    return StructuredResume(
        name=name,
        email=email_match.group(0) if email_match else None,
        skills=skills,
        projects=_clean_entries(sections.get("projects", [])),
        experience=_clean_entries(sections.get("experience", [])),
        education=_clean_entries(sections.get("education", [])),
        certifications=_clean_entries(sections.get("certifications", [])),
    )
