"""AI stages — every place in CogniHire where a model decides something.

Each module is one stage with one responsibility, all reaching a vendor only
through `provider.chat_json()`. No stage knows which provider answered, and no
API key or prompt exists outside this package. Because every stage shares that
one interface, models can be swapped per-stage independently.

## The candidate profile is the centre, not the interview

```
Resume PDF
   ↓  deterministic/pdf_extraction
Resume text
   ↓  resume_understanding          [AI]  ⟨grounded⟩
CANDIDATE KNOWLEDGE PROFILE  ←── the canonical object
   ↓  claim_extraction              [AI]  ⟨grounded⟩
Grounded claims
   ↓  question_planning             [AI]  ⟨grounded⟩
Question plan
   ↓  interview + coverage_manager  [AI]  ⟨topic phrasing only, no new facts⟩
Question / follow-up
   ↓  [ candidate answers — outside this package ]
   ↓  answer_analysis               [AI]  ⟨evidence_quote grounded in the answer⟩
Verdict → coverage_manager.evaluate → next interview turn (loop)
   ↓  evidence_linking               [deterministic] reshapes the event log
Claim ← evidence links
   ↓  report_generation              [deterministic] reshapes the links
Transparent report
```

`resume_understanding` is the **last stage that sees raw resume text**.
Everything after it reads the profile. That is what makes improving how a
candidate is understood a one-stage change rather than a pipeline-wide one,
and what leaves room for embeddings or retrieval to be added as a stage that
enriches the profile without any consumer changing.

## Three verification rules, for three different kinds of output

Stages emitting *quotations from the resume* (skills, claims, a plan topic's
`grounded_in`) pass through `deterministic/grounding.py`: verbatim in the
source, or discarded.

Stages emitting *conclusions about the candidate* (domains, strengths,
estimated focus) cannot be gated that way — they are readings, not quotes —
so each must cite grounded evidence, and one whose basis does not survive is
dropped. See `knowledge_profile.Inference`.

`answer_analysis` grounds a third kind: its `evidence_quote` is checked
against the CANDIDATE'S SPOKEN ANSWER, not the resume — a model may judge that
an answer is convincing, but the sentence it cites as proof must actually be
in that answer.

`interview` generates question *phrasing*, which is not itself a claim about
the candidate and so is not gated the same way — but it is restricted to a
plan topic's already-grounded material, and forbidden from asserting new facts
in the question's own voice. `coverage_manager` makes no model call at all: it
is bookkeeping over decisions the other stages already made.

None of this is enforced by a model. See `test_architecture_boundary.py`.
"""

from . import (
    answer_analysis,
    claim_extraction,
    coverage_manager,
    evidence_linking,
    interview,
    knowledge_profile,
    provider,
    question_planning,
    report_generation,
    resume_understanding,
)

__all__ = [
    "provider",
    "knowledge_profile",
    "resume_understanding",
    "claim_extraction",
    "question_planning",
    "interview",
    "answer_analysis",
    "coverage_manager",
    "evidence_linking",
    "report_generation",
]
