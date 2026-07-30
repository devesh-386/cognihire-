# CogniHire AI — Mentor Brief
## One-Page Executive + Technical Deep-Dive

---

# ⚡ ONE-PAGE EXECUTIVE SUMMARY

## The Opportunity

**Problem:** AI hiring tools verify identity once at login, then assume all work is the candidate's own. No system adapts the interview based on *how* the candidate works—and no one verifies *who* is still at the keyboard.

**Solution:** CogniHire is a pre-screening gate that does two things existing platforms don't:
1. **Continuous identity verification** (facial embedding matching, 15–25s windows)
2. **Adaptive questioning** (follow-ups triggered by keystroke patterns; candidate explains live)

Result: recruiter gets a transparent audit (*who* did what, *how* they approached it) instead of a score.

## Why Now

- **Market gap:** the three platforms that own this space — HireVue, HackerRank, CodeSignal — all treat process as a retrospective fraud flag. None adapt the live interview from it.
- **Regulatory tailwind:** NYC LL144, Illinois AIVI (2026-01-01), EU AI Act all push hiring tools toward audit trails and away from opaque scores
- **Market signal:** Google reinstated in-person rounds for certain roles after a Feb 2025 town hall (CNBC); a16z put **$15M** into Cluely, which markets "cheat on everything" (TechCrunch). Decisions by parties with money at stake — not vendor flag-rate statistics.
- **HireVue precedent:** facial analysis contributed ~0.25% of predictive value; they dropped it in Jan 2021. We don't build weak signals.

## The Ask

**What you're looking at:**
- Working Flutter prototype (Windows + Android + Web, 69 tests, end-to-end)
- Python face service (InsightFace embeddings, ONNX Runtime, no fine-tuning)
- Claim audit (structured, transparent, no hidden scoring)
- Research-validated positioning (market + regulatory landscape mapped)

**What's next:**
- Threshold calibration (FAR/FRR on real data)
- Persistence layer (multi-run demos)
- Claim extraction (resume → claims)
- Customer validation (pilot with 1–2 recruiting teams)

**Built solo in 48 hours. 69 tests green. No fabricated fallbacks.**

---

---

# 🔬 TECHNICAL DEEP-DIVE

## 1. Core Innovation: Provenance + Process

### The Identity Problem
Traditional hire-by-code platforms:
- ✅ Verify identity at login
- ❌ Never re-verify mid-task
- ❌ Can't detect substitution or remote assistance
- ❌ No way to distinguish the candidate's own thinking from borrowed code

**CogniHire solves:** continuous biometric verification + process telemetry that flags anomalies and adapts questioning.

### The Process Problem
HackerRank / CodeSignal:
- ✅ Record keystroke playback (HackerRank's "Keystroke Codeplayer"; CodeSignal reportedly a "Suspicion Score" — *unconfirmed, see §7*)
- ❌ Playback is *retrospective* — flagged for human review after the fact
- ❌ Never fed into the live interview to ask follow-up questions
- ❌ No mechanism to distinguish "candidate explaining their own code" from "second device reading answers"

**CogniHire solves:** three trigger patterns (`bulkInsert`, `pauseThenBulk`, `immediateAnswer`) generate rule-selected follow-ups. Candidate must comprehend *live, in their own words* — materially harder than producing/pasting.

---

## 2. Architecture: No Fabricated Fallbacks

| Component | Standard Risk | CogniHire Approach |
|-----------|---------------|--------------------|
| **Missing embedding** | Return 0-vector, treat as low match | Return `null`; verification state = `Unchecked` (reason: "no face detected") |
| **Failed face detection** | Invent confidence score | Service reports `face_detected: false`; app never generates a "match" |
| **Zero verification attempts** | Claim 100% coverage (false) | Identity coverage = `null`, never computed |
| **Broken face service** | Fall back to a heuristic | Service starts but reports `engine_available: false`; app hard-stops |
| **Ambiguous edge cases** | Silent pass/fail decision | All verdict logic in one authored rules engine (testable, auditable) |

**Philosophy:** Broken components report broken. The deck claims no emotion inference; we don't load `genderage.onnx` at all. "Could not measure" is never "passed."

---

## 3. Working Prototype: What's Built

### Flutter App (`C:\claude\cognihire`)
**69 tests green | `flutter analyze` clean | Builds + launches Windows | Targets: Windows, Android, Web**

#### Core Logic (Pure Dart, fully testable)
```
core/
├── config.dart              # FACE_SERVICE_URL, thresholds
├── verification/
│   ├── verification_result.dart    # ✅ Sealed: Verified | Mismatch | Unchecked
│   ├── identity_matcher.dart       # Cosine similarity (0.50 threshold)
│   ├── face_engine.dart            # HTTP client to Python service (strict error handling)
│   └── verification_session.dart   # Continuous 15–25s loop, strike counter, streams
├── integrity/
│   ├── violation_rules.dart        # Escalation table (20–100 points)
│   └── integrity_tracker.dart      # Rule application
├── telemetry/
│   ├── process_telemetry.dart      # Keystroke classification
│   └── edit_event.dart             # Structural enum (nulls mean "not measurable", never 0)
├── interview/
│   └── followup.dart               # Follow-up generator (rule-selected, not AI-scored)
└── claims/
    ├── claim.dart                  # Claim + ClaimStatus (substantiated/contradicted/notExamined)
    └── claim_audit.dart            # Audit builder with ProvenanceQuality
```

#### Features (UI)
```
features/
├── enrolment/
│   ├── enrolment_screen.dart       # Real camera, rejects too-small face with guidance
│   └── enrolment_controller.dart   # Sealed: EnrolmentCaptured | Rejected | Failed
├── interview/
│   ├── interview_screen.dart       # ✅ THE unified session (camera + identity + task + audit)
│   ├── interview_controller.dart   # State machine (13 tests): claims → telemetry → follow-ups → audit
│   └── interview_controller_test   # Verified state transitions
├── session/
│   ├── verification_status_card.dart  # Three visually distinct states
│   └── session_screen.dart         # [DEPRECATED] — candidate for deletion
├── audit/
│   └── claim_audit_screen.dart     # Reviewer-facing report (no recommendation, transparent)
└── task/
    └── task_screen.dart            # Telemetry sandbox for testing
```

#### Test Coverage (69 tests)
- `core_logic_test.dart` (11) — verification types, thresholds, sealed state transitions
- `verification_session_test.dart` (9) — jittered timing, strike escalation, stream behavior
- `enrolment_controller_test.dart` (6) — face size validation, rejection paths
- `process_telemetry_test.dart` (12) — keystroke classification, edit event signals
- `followup_test.dart` (6) — trigger patterns, rule selection
- `claim_audit_test.dart` (12) — audit building, provenance quality tagging
- `interview_controller_test.dart` (13) — state machine, claim sequencing, audit finalization

### Python Face Service (`C:\claude\cognihire\service`)
```
main.py
├── POST /face/analyze
│   ├── Input: image (base64)
│   └── Output: {
│        engine_available: bool,
│        face_detected: bool,
│        embedding_available: bool,        ← null if can't measure, never zero-vector
│        embedding: float[512],             ← ArcFace on WebFace600K
│        face_size: int,
│        brightness: float,
│        sharpness: float,
│        recommendations: [str]
│      }
└── GET /health → {status: "ok"}
```

**Models (2 only, deliberately):**
- **SCRFD** `det_10g.onnx` — face detection
- **ArcFace** `w600k_r50.onnx` — 512-d embeddings (ResNet-50 on 600K web faces)

**Zero ML training, zero fine-tuning:** Everything beyond embeddings is arithmetic (cosine) + authored rules.

---

## 4. Threshold Justification (Why 0.50?)

| Approach | Threshold | Problem |
|----------|-----------|---------|
| Friend's code | raw 0.70 (rescaled: ≥85) | Rejects genuine candidates; unrelated faces ~50% (misleads reviewers) |
| ArcFace literature | 0.4–0.5 | Assumes one enrollment; unsituated in hiring context |
| CogniHire | 0.50 raw cosine | Purposefully stricter (guards against lookalike exploitation); `displayConfidence` maps unrelated→~0 (transparent to reviewers) |

**Not yet validated:** Real FAR/FRR on candidate pairs (P2 roadmap). Current threshold is *reasoned*, not measured. We don't quote FAR/FRR until calibration data exists.

---

## 5. Claim Audit: The Deliverable to HR

Instead of a score, recruiters get:

```json
{
  "candidateId": "alice-2026-07-27",
  "claims": [
    {
      "text": "Built a REST API in Node.js",
      "status": "substantiated",
      "evidence": {
        "claimedSkill": "Node.js",
        "demonstratedVia": "task_completion",
        "taskDetails": "Implemented /users endpoint with auth",
        "verificationAttempts": 4,
        "identityMismatches": 0,
        "suspiciousPatterns": []
      },
      "provenanceQuality": "solid"
    },
    {
      "text": "Expert in machine learning",
      "status": "notExamined",
      "evidence": null,
      "provenanceQuality": "none"
    }
  ],
  "overallProvenanceQuality": "solid",
  "reviewerNotes": "No recommendation. All identity checks passed. No anomalous keystroke patterns.",
  "sessionDuration": "18 minutes",
  "flaggedForHumanReview": false
}
```

**Key design choice:** No hire/no-hire recommendation. No silent auto-reject. Flagged queue → recruiter reads the audit and decides.

---

## 6. What We Deliberately Don't Build

| Feature | Why Not |
|---------|---------|
| **Facial emotion / personality inference** | Contested science — facial movement is not a measure of ability. Discrimination risk under IHRA / AIVI. |
| **Single composite score** | NYC LL144 (audit required). Illinois AIVI (eff. 2026-01-01). EU AI Act (high-risk). Opaque verdicts fail under all three. |
| **Typing speed as ability** | No established link to code quality, and it penalises people with motor differences. *(Our design position — we have no study to cite for it.)* |
| **Generic behavioral scoring** | HireVue's own audit put facial analysis at ~0.25% of predictive value; they dropped it. |
| **Demographic inference** | We don't load the gender/age classifier at all (saves ~143MB; prevents data leakage). |
| **Virtual camera fallback** | Wrong camera = the app says so and blocks. Never invents data. |

---

## 7. Validation & Market Research

### Competitor Landscape (three platforms examined in depth)
| Platform | Provenance | Live Adaptive Process | Audit Trail | Regulatory Exposure |
|----------|-----------|----------------------|------------|----------------------|
| HireVue | ✅ Video | ❌ Score only | ⚠️ Opaque | ⚠️ 2019 FTC complaint (EPIC); dropped facial analysis Jan 2021 |
| HackerRank | ❌ Login only | ⚠️ Playback (retrospective) | ⚠️ Internal flag | ⚠️ No audit |
| CodeSignal | ❌ Login only | ⚠️ Playback + "Suspicion Score" *(unconfirmed)* | ⚠️ Limited | ⚠️ No formal audit |
| **CogniHire** | ✅ Continuous | ✅ Live follow-ups | ✅ Structured audit | ✅ Designed in |

*Every cell above is from the vendor's own capability documentation or independent press. Vendor-reported **metrics** (flag rates, accuracy percentages) are deliberately excluded — a flag is not a cheat, and the vendor profits from the number being large.*

### Customer Validation — NOT YET DONE
**No recruiters or hiring managers have been interviewed.** Demand is currently inferred from the competitive gap and the regulatory direction, not measured. Treat it as the project's largest untested assumption.

What would validate it, in order:
1. 5–8 technical recruiters: does "who did the work" rank above "how good is the work" for screening?
2. Would a claim audit with no recommendation actually get used, or does a busy recruiter want a score anyway?
3. What does a screening pass cost them today in hours per candidate?

### Market Signal (independent, in place of vendor statistics)
- **Google** reinstated at least one in-person round for certain roles after employees asked at a Feb 2025 town hall; Pichai endorsed it ([CNBC](https://www.cnbc.com/2025/03/09/google-ai-interview-coder-cheat.html))
- **Cluely** — reads live audio and screen content to feed real-time interview answers, branded "cheat on everything" — raised **$15M** led by a16z ([TechCrunch](https://techcrunch.com/2025/06/20/cluely-a-startup-that-helps-cheat-on-everything-raises-15m-from-a16z)). Its CEO later admitted a publicised $7M ARR figure was untrue ([Inc.](https://www.inc.com/leila-sheridan/an-a16z-backed-startup-that-helps-people-cheat-on-job-interviews-just-got-caught-in-a-7-million-lie-the-ceo-was-sweating/91313070))

### Regulatory Landscape
- **NYC Local Law 144** (2023): "bias audit" required for automated employment decisions
- **Illinois AI Video Interview Transparency Act + IHRA amendment** (eff. 2026-01-01): biometric processing subject to disclosure + consent
- **EU AI Act** (2024): hiring = high-risk; "human oversight" required; explainability mandatory

---

## 8. Roadmap: Validated → Production

### P0 — Demo-Ready (DONE)
- [x] Working end-to-end prototype
- [x] 69 green tests
- [x] Research audit complete
- [x] Pitch decks research-aligned

### P1 — Multi-Run Demos (8–12 days)
- [ ] Persistence layer (SQLite: enrolments, sessions, audits)
- [ ] Claim extraction (LLM: resume → structured claims)
- [ ] Audit export (PDF / email / webhook)

### P2 — Credibility & Production (14–20 days)
- [ ] **Threshold calibration** (collect 50+ same-person / different-person pairs; validate FAR/FRR)
- [ ] Android testing (best-supported camera; Windows is weakest)
- [ ] CORS hardening (service: `allow_origins` restricted to known domains)
- [ ] Python version lock (`requirements.txt` pinning)

### P3 — Nice to Have (later)
- [ ] Candidate-facing transparency view
- [ ] Recruiter override + audit trail
- [ ] Session replay
- [ ] Multi-candidate dashboard

---

## 9. Technical Debt & Gotchas

### Critical (Don't overclaim)
1. **Threshold is reasoned, not validated.** Quote no FAR/FRR until P2 calibration.
2. **Process telemetry is 3 patterns only.** Not a full keystroke analysis. Second device *could* rehearse answers, but adversarial follow-ups make that materially harder.
3. **Flutter camera support is uneven:** Android > Web > Windows. Windows is the current dev target; Android is the production target.

### Known Bugs (Fixed)
- ❌ `buffalo_l` loads gender/age classifier by default → was 143MB + demographic inference claim issue
  - ✅ Fixed 2026-07-27: explicit `allowed_modules=['detection','recognition']`
- ❌ Camera handoff between screens throws "Camera with given device id already exists"
  - ✅ Fixed: explicit `dispose()` before navigation + backoff retry
- ❌ `navigator.pushReplacement` builds new route before disposing old one
  - ✅ Fixed: explicit release + delay on new screen

### No Hard Blocker
**None.** Prototype is end-to-end working. All roadmap items are *additive*, not fixes.

---

## 10. Why This Matters

**For hiring:** Closes a market gap (continuous provenance + adaptive process not commoditized). Defensible legally (audit trail, no black-box scoring, transparent rules). Built for trust (recruiter-friendly, candidate-friendly).

**For you:** Ship a working system in 48 hours. Validate market assumptions. A customer pilot is the next step, not more features.

**For regulators / courts:** When (not if) hiring AI is audited, CogniHire has the receipts—who did what, why, when, and a structured log. No fabricated confidence scores. No demographic inference. No accusation; just evidence.

---

## Next Steps

**With your mentor:**
1. Walk through the working prototype (5 min demo)
2. Show the audit output (what HR receives)
3. Discuss P1 roadmap (persistence → claim extraction → export)
4. Plan customer validation (who to talk to, what to measure)

**Materials to bring:**
- Prototype (Windows build)
- Market research deck (PDF)
- Pitch deck (PowerPoint)
- This brief (print or email)

---

**Solo build, 2026-07-26 to 2026-07-27. 69 tests green. Research audit complete. Ready to validate with customers.**
