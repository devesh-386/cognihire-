# Audit of the reference build (`D:\interview sys`)

Full read of the friend's React + FastAPI project, done 2026-07-26 to decide what
CogniHire should inherit. That codebase is **inspiration and cautionary tale, not
a dependency** — nothing here imports from it.

Verdict summary: the computer-vision core is real and worth porting. The
decision layer around it is largely fabricated, and the fabrications share one
root cause that this project is architected specifically to prevent.

---

## 1. What is real (port the idea, rewrite the code)

| Component | Status | Notes |
|---|---|---|
| InsightFace `buffalo_l` embeddings | **Real, verified** | 512-dim embeddings. Confirmed working locally: 2 faces found in the test image, self-match raw cosine 1.00, two different people 0.012. |
| Cosine similarity comparison | **Real** | Correct maths. The *threshold* on top of it is wrong — see §3. |
| COCO-SSD object detection | **Real, but was dead on arrival** | Detects phone / book / laptop / person. It never actually ran — see §2.1. Now confirmed working: on a test image it returned 3× person (0.99/0.86/0.85), 2× laptop, cup, chair. |
| Focus-loss & fullscreen-exit tracking | **Real** | Straightforward DOM events. Sound. |
| Escalating penalty model | **Real, sound design** | `baseWeight + (occurrence-1)*2`, capped at 100. Ported as-is into `IntegrityTracker`. |
| Sustained-violation termination | **Real** | 30s of continuous violation ends the session. Reasonable policy. Ported as the strike model. |
| Password hashing | **Real** | PBKDF2-HMAC-SHA256, 100k iterations, per-user salt, `hmac.compare_digest`. Genuinely fine. |
| SQLAlchemy schema | **Real** | Sensible relational model. Good reference for our data design. |

## 2. What is fabricated (do not port — these are the anti-patterns)

### 2.1 The object detector never ran, and its "backup" invented evidence
`detector.js` loaded COCO-SSD with `base: 'lite'` — not a valid name (valid:
`mobilenet_v1`, `mobilenet_v2`, `lite_mobilenet_v2`). The model threw on **every**
load, so real object detection never executed once.

What filled the gap was a luminance heuristic in `WebcamMonitor.jsx`: if the left
or right third of the frame deviated >60% from mean brightness for 3 consecutive
frames, it logged `PHONE_DETECTED` or `BOOK_DETECTED` — labelled
**"(Camera Verified)"**. A window, a desk lamp, or a light-coloured shirt was
sufficient. Those fabricated events then fed the escalating penalty system.

Compounding it: the load-failure handler set the status string to
`'AI Proctoring Engine Ready'`, and that status was **never rendered anywhere**,
so a total detector outage was invisible in the UI.

### 2.2 Identity verification fabricated a pass
`/face/verify` returned `{"verified": true, "similarity_score": 98.7, "confidence": 0.98}`
when no enrolled face profile existed. A confident pass, manufactured from
missing data.

### 2.3 The resume parser invents its own output
`ATSService.analyze_resume` substring-matches 14 hardcoded keywords, then:
```python
"matched_skills": matched if len(matched) > 0 else ["React", "FastAPI", "Python"],
"missing_skills": missing if len(missing) > 0 else ["Docker", "Redis"],
```
On zero matches it returns a plausible-looking hardcoded list. It also floors the
score at 20.0, so a completely unrelated resume never scores below 20. And
`/resume/analyze` ignores the uploaded file entirely — it parses a hardcoded
`mock_resume_text` constant.

### 2.4 Speech analytics measures nothing
`SpeechAnalyticsService.parse_fluency` takes **text, not audio**. It derives
"pause time" as `filler_count * 0.8 + word_count * 0.05` and words-per-minute as
`150 - filler_count * 3`. There is no timing data anywhere in the input. Every
number it reports is arithmetic on a filler-word count.

### 2.5 The JWT is not a JWT
`auth.py` builds a token as `header.mockPayload.{email}.{role}.signature`. The
header is a hardcoded base64 string; the payload is not base64-encoded JSON. The
HMAC signature is real, so it is tamper-evident — but `decode_access_token`
splits on `.` and reads positional fields, and the expiry timestamp is placed in
the signed payload dict yet **never checked on decode**. Tokens do not expire.

Worse, no endpoint calls `decode_access_token` at all. `/face/register`,
`/face/verify`, and `/biometric/analyze` each do `db.query(models.User).first()` —
they operate on **whichever user happens to be first in the table**, regardless of
who is authenticated. Auth exists but is not wired to authorisation.

### 2.6 Dead computation presented as capability
SIFT / SURF / ORB keypoints are computed on every frame, stored in the database,
and displayed — but never used in any decision. SURF is unavailable in standard
OpenCV builds and silently reports `-1`.

### 2.7 Leaked credential
A live Gemini API key was hardcoded at `services.py:7` and committed across ≥3
commits. Removed from the working copy on 2026-07-26 (now read from an env var),
**but the key remains valid and remains in git history** — only the account owner
can revoke it.

---

## 3. The threshold bug worth understanding before porting

The reference rescales cosine similarity with `(cos + 1) / 2 * 100` and requires
`>= 85` to pass. Measured against `buffalo_l` on this project's own images:

| comparison | raw cosine | rescaled |
|---|---|---|
| same face, identical image | 1.00 | 100.0 |
| same face, degraded (blur / jpeg q40 / ±light / rotate) | 0.91–0.99 | 95.7–99.4 |
| **two different people** | **0.012** | **50.6** |

Two problems:

1. **The scale is misleading.** It compresses everything into 50–100. An
   impostor scores ~50%, which reads to a human as "half a match" when it means
   "unrelated person". Never show this number to a reviewer unmodified —
   `IdentityMatcher.displayConfidence` exists to map the usable band onto 0–100.
2. **85 rescaled == raw cosine 0.70**, far stricter than the ~0.4–0.5 normally
   used with ArcFace embeddings. The degradation row above looks reassuring but
   those are transforms of a *single* photo; genuine same-person variation across
   separate sessions is much wider. A 0.70 bar would reject real candidates.

CogniHire defaults to raw 0.50 (75 rescaled). **This is reasoned, not
validated** — calibrating it needs pairs of genuinely separate captures of the
same person, which we do not have yet. Until then, quote no false-accept or
false-reject rate anywhere.

---

## 4. The single root cause, and the architectural answer

§2.1, §2.2, §2.3 and §2.4 are not four unrelated bugs. They are one habit:
**treating "I could not measure this" as "this passed"** (or as a confident
number). A product whose entire pitch is verifiable evidence cannot afford that
habit anywhere — one discovered fabrication discredits every real component
beside it.

CogniHire's answer is structural rather than disciplinary:

- `VerificationResult` is a **sealed class** with `Verified` / `Mismatch` /
  `Unchecked`. "Could not measure" is a distinct variant carrying a reason, with
  no similarity field — because there is no honest number to put in it. Callers
  must handle it; there is no default that decays into a pass.
- `Unchecked.isVerified` returns **false**, and `didMeasure` returns **false** —
  so an unmeasured interval can be told apart from a failed one, and neither
  silently reads as success.
- Detector availability is surfaced in the UI, not swallowed. "Unavailable" must
  look different from "nothing detected".
- Only measured events reach `IntegrityTracker`. Escalating penalties on top of
  fabricated events is how a candidate gets failed by a desk lamp.

---

## 5. What is missing entirely from the reference

No code editor, no keystroke or process telemetry, no claim extraction, no
adversarial follow-up, no HR-facing report view, and no voice pipeline (the
"speech analytics" is §2.4). These are CogniHire's actual product surface and
must be built from scratch — there is nothing to port.
