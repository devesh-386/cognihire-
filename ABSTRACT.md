# CogniHire AI — Verified-Claim Interview Intelligence

## Executive Summary

CogniHire is a pre-hiring screening system that verifies candidate claims through continuous identity verification and adaptive questioning, positioning it as a provenance and process gate rather than a scoring system. Unlike existing AI interview platforms that infer ability from answer quality, CogniHire answers two distinct problems: *who provided the answer* (provenance) and *how they approached the problem* (process), both verified live and fed into adaptive follow-ups.

---

## The Problem

Current AI hiring tools operate under a **single-point identity model**: verify identity at login, then assume all subsequent work is the candidate's own. This creates three vulnerabilities:

1. **Provenance gap** — no mechanism to detect mid-interview substitution or unauthorized remote assistance
2. **Process blindness** — coding platforms (HackerRank, CodeSignal) record process for *retrospective* fraud flagging, but never adapt the interview based on what they observe
3. **Silent auto-reject** — candidates fail without understanding why, and systems risk regulatory exposure under NYC LL144, Illinois AIVI Act (2026), and EU AI Act high-risk provisions

---

## The Solution

**Working prototype** (Flutter + Python/InsightFace, 69 tests, end-to-end) that:

### 1. **Continuous Provenance Verification**
- Real-time facial embedding matching (512-d ArcFace on WebFace600K)
- Jittered verification window (15–25s cadence) with escalating strikes
- Sealed output states: `Verified`, `Mismatch`, or `Unchecked` (never fabricated pass)
- Threshold rationale: 0.50 raw cosine similarity (defensibly stricter than ArcFace norms)

### 2. **Adaptive Process Verification**
- Task telemetry: keystroke patterns, pause timing, edit sequences classified as *measurable* signals (not "intent" or "confidence")
- Adversarial follow-ups triggered by three patterns:
  - `bulkInsert` — sudden mass keystroke activity
  - `pauseThenBulk` — silent gap then rapid text
  - `immediateAnswer` — no pause before responding
- Follow-ups select from a rule-based template library, never algorithmically score confidence
- A candidate explaining their own pasted code answers well; a second device must comprehend and articulate live

### 3. **Transparent Claim Audit** (not a grade)
- Per-claim evidence bundle: substantiated / notDemonstrated / contradicted / notExamined
- Provenance quality tagged: solid / disputed / sparse / none
- Explicitly no hire/no-hire recommendation — flagged queue to human recruiter
- Never a silent auto-reject

---

## Why This Matters: Architectural Decisions

| Decision | Why |
|----------|-----|
| **No ML labels anywhere** | Answers "where does your training data come from." No Amazon-2018 toxic labels, no profit motive to inflate cheating rates. |
| **Detect, deter, document—never prevent** | No app stops a second device. Claiming prevention loses credibility; transparent detection + audit preserves trust. |
| **Structured fabrication prevention** | Missing embeddings return `null`, never zero-vector. Zero attempts = `null` identity coverage, never 1.0. Broken components report broken. |
| **No single composite score** | Regulatory ceiling: Illinois AIVI + IHRA, NYC LL144, EU AI Act all flag algorithmic hiring scores. Authored verdicts answer "why." |
| **No demographic inference** | The InsightFace pack ships a gender/age classifier; we load `detection` and `recognition` only, so it never runs on a candidate's face. |
| **Verdict logic in one place** | Service extracts; client (rules engine) decides. No hidden scoring in the backend. |

---

## Evidence & Market Research

**Competitor positioning** (three platforms examined in depth — HireVue, HackerRank, CodeSignal):
- **HireVue** — composite scoring + video analysis. Discontinued facial analysis in January 2021 after an algorithm audit found it contributed roughly **0.25%** of predictive value (Fortune, SHRM). Subject of a 2019 FTC complaint filed by EPIC.
- **HackerRank** — ships keystroke playback ("Keystroke Codeplayer") and session replay, filed as a retrospective fraud flag for human review.
- **CodeSignal** — playback plus a "Suspicion Score". ⚠️ *Currently sourced only from HackerRank's competitor comparison post; unconfirmed against CodeSignal directly.*
- **Gap identified** — process is captured for the coding task and reviewed *after* submission. No vendor feeds it back into a live interview that adapts its next question.

**Regulatory backdrop:**
- NYC Local Law 144 (2023): "bias audit" required for automated employment decisions
- Illinois AI Video Interview Transparency Act (2026-01-01): biometric processing + IHRA amendment
- EU AI Act high-risk classification for hiring tools

**Market signal** — the strongest available evidence is behaviour by parties with money at stake, not vendor-reported flag rates:
- Google reinstated at least one in-person round for certain roles after a February 2025 town hall; Sundar Pichai endorsed the shift (CNBC).
- **Cluely** — an assistant that reads live audio and on-screen content to feed real-time interview answers, branded "cheat on everything" — raised **$15M** led by a16z (TechCrunch).

**Not yet done: customer validation.** No recruiters or hiring managers have been interviewed. Demand is inferred from the regulatory and competitive picture above, not measured. This is the single largest untested assumption in the project and the first item on the validation roadmap.

---

## Technical Foundation

**Flutter prototype** (Windows + Android + Web):
- 69 tests (core logic, verification session, telemetry, audit generation)
- `flutter analyze` clean; real camera integration
- Pure Dart verification stack (testable, no platform dependencies for logic)

**Python face service** (FastAPI + ONNX Runtime CPU):
- InsightFace `buffalo_l`, detection + recognition modules only (SCRFD detection + ArcFace 512-d embeddings)
- Strict error reporting: `embedding` is `null` when it cannot be measured, never a zero-vector. If the engine fails to load, the service still starts and reports `engine_available: false` rather than falling back to a heuristic.
- Health check + structured telemetry

**No fine-tuning, no training labels:**
- Cosine similarity: arithmetic
- Threshold (0.50): authored constant — **reasoned, not yet validated.** Calibration is P2; no FAR/FRR is quoted until it exists.
- Integrity escalation (20–100): IF/THEN rules, not learned weights
- Telemetry classification: pattern matching, not a classifier

---

## What We Deliberately Don't Build

- **Facial emotion / personality inference** — contested science + discrimination risk
- **Single composite "hire score"** — regulatory ceiling + opaque decision
- **Typing speed as ability** — no established link to code quality, and it penalises motor differences (our design position, not a cited finding)
- **Generic behavioural questions scored** — the signal HireVue itself measured at ~0.25% and dropped
- **Virtual-camera fallback** — wrong camera = says so, never invents

---

## Next Steps (Prioritized)

| Priority | Blocker | Effort | Impact |
|----------|---------|--------|--------|
| **P0** | None (demo-ready) | Done | Mentor review + pitch refinement |
| **P1** | Data persistence | 8h | Multi-run demos, realistic evaluation |
| | Claim extraction (resume → claims) | 16h | Close front-of-funnel gap |
| | Audit export (PDF/share) | 6h | HR workflow integration |
| **P2** | Threshold validation | 12h | Quote FAR/FRR with confidence |
| | Android testing | 4h | Production-grade platform support |

---

## Why This Matters for Hiring

1. **Closes a market gap** — continuous provenance + live-adaptive process is not commoditized
2. **Defensible legally** — audit trail, no black-box scoring, transparent rules
3. **Built for trust** — recruiter-friendly (no auto-reject), candidate-friendly (clear why flagged)
4. **Research-backed where it counts** — competitive and regulatory landscape mapped and sourced. Customer demand is *not* yet validated; that is the next step, not a claim.
5. **Working code, not theory** — end-to-end prototype, testable, ready to validate further assumptions

---

## Contact & Next Steps

**For mentor feedback:**
- Visual review of pitch decks (12-slide PowerPoint + interactive HTML)
- Technical depth: core logic fully tested and documented
- Roadmap: threshold validation → customer pilot → enterprise features

**Prototype access:** Windows build ready; requires Python 3.9+ and `pip install -r service/requirements.txt` for the face service.

---

**Built solo over 2 days (2026-07-26 to 2026-07-27). 69 tests green. Research audit complete.**
