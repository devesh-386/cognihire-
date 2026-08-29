# CogniHire — Testing and Verification

**Verified 2026-08-28 by running every suite.**

| Suite | Files | Tests | Result |
|---|---|---|---|
| Flutter / Dart | 64 | **689** | Pass (+3 excluded, see §4) |
| Python / FastAPI | 36 | **417** | Pass |
| Portal / Vitest | 1 | 6 | Pass |
| **Total** | **101** | **1 112** | |

`flutter analyze` reports no issues. CI is green on `main`.

> Older documents in this repository quote 69, 662, 674, 681, 686, 688, 734, a 1 100 total with
> 412 Python / 2 portal, or a 1 109 total with 686 Dart. Those are historical snapshots. **689 Dart, 417 Python and 6 portal
> are the current, verified figures.** The 412 in an earlier revision of this file was simply
> wrong rather than a counting convention: 417 pass with zero skipped.

---

## 1. Testing philosophy

Conventional tests check that code does what it is supposed to do. This project additionally uses
tests to guarantee that code **cannot** do what it is not supposed to do.

The distinction matters because CogniHire's central claims are negative ones: the AI does not author
claims; no composite score exists; an unmeasured check is not a pass. A negative claim cannot be
demonstrated by a feature test — it has to be enforced, or it decays the moment attention moves
elsewhere.

We therefore keep three categories:

1. **Behavioural tests** — does it work.
2. **Invariant tests** — is a design decision still true (§2).
3. **Golden/preview tests** — has the UI drifted (§4).

---

## 2. Invariant tests — the load-bearing ones

These three fail the **build**, not merely a feature.

### 2.1 The grounding boundary
`service/test_architecture_boundary.py`

Asserts that `service/deterministic/grounding.py` does not import from `service/ai/`.

This is what converts "the AI may select claim text but never author it" from a policy into a
guarantee. A developer who wires the model into the gate discovers it in CI, not in production. The
project's headline claim is therefore checkable by anyone in about thirty seconds, without trusting
the authors.

### 2.2 The vocabulary ban (ED-46)
`.github/workflows/guardrails.yml` + `tools/lint/`

Fails the build if a composite-score-shaped field is introduced anywhere in the AI data-transfer
objects. "We do not produce a score" stays true because a score cannot be added quietly.

### 2.3 The evidence↔disposition fence (ED-45)
`.github/workflows/guardrails.yml`

Fails the build if a schema change creates a join between evidence data and disposition (outcome)
data. This is the structural guarantee behind "no hiring-outcome labels exist" — the two sides
cannot be correlated because they cannot be joined.

---

## 3. Coverage by module

| Module | Representative tests |
|---|---|
| Grounding gate | `service/test_architecture_boundary.py`, negation/hedge cases |
| Claim extraction | verbatim-substring property tests |
| Interview engine | session state machine, coverage manager |
| Report generation | verdict derivation; **absence of any score field** |
| Access control | `service/test_access_control.py` — default-deny, `PUBLIC_PATHS` |
| Interview codes | expiry, revocation, attempt limits |
| Email workflow | `service/test_email_routes.py`, idempotent send |
| End-to-end | `service/test_end_to_end.py` — résumé text → claims → session |
| ML pipeline | `service/ml/tests/test_pipeline.py` — planted-weight recovery |
| Verification types | `Unchecked` carries no similarity field |
| Evidence graph | edges require a non-empty rationale at construction |
| Persistence | strict codec — unknown enum, wrong `schemaVersion` ⇒ `FormatException` |
| RBAC | route guard, permission matrix, tenancy |
| Feature store | `feature_vector_golden_fixture_test.dart` |
| Portal | `interview-flow.test.tsx` — live-voice fallback to typed path |

---

## 4. Known non-blocking failures

Three tests in `test/preview/ui_preview_test.dart` fail locally:
`home compact`, `home wide dark`, `home wide light`.

**Cause:** `google_fonts` attempts to fetch `RobotoSlab-Regular` from `fonts.gstatic.com` at test
time. In an offline environment the fetch fails, the fallback font renders, and the golden
comparison reports a ~99.8 % pixel difference. The failure is font loading, not layout.

**Handling:** these tests are tagged `preview`, and CI runs
`flutter test --exclude-tags=preview`. They are intended to be run deliberately, with network
access, when reviewing UI changes.

**Not a product defect.** No shipped code path depends on `fonts.gstatic.com`; fonts were
deliberately not added to the runtime bundle precisely to keep the app functional offline.

---

## 5. Continuous integration

| Workflow | Trigger | Purpose |
|---|---|---|
| `test.yml` | every push | Flutter (excluding `preview`), Python, portal |
| `guardrails.yml` | every push | The three invariant tests (§2) |
| `deploy.yml` | `workflow_run` after Tests succeeds | Deploy to Azure VM |
| `ssh-connectivity-test.yml` | manual | Diagnose deploy connectivity |
| `configure-smtp.yml` | manual | Provision SMTP secrets |

**Deployment is gated on tests.** `deploy.yml` triggers on `workflow_run` completion of Tests and
runs only if `conclusion == 'success'`. Before this gate existed, a broken commit deployed exactly as
readily as a working one.

**Deployment asserts its own freshness twice** — the VM-local `/health` must report the exact
deployed `git_sha`, and then the public endpoint must report it too. A build that silently failed to
replace the running container cannot report success, and neither can a stale CDN cache.

---

## 6. Security verification

Independent structured audit, 2026-08-24 (`.gstack/security-reports/`).

**Attack surface:** 17 public endpoints, 23 authenticated, 41 API total, 3 upload paths,
5 integrations, 2 background jobs, 1 WebSocket, 6 CI workflows, 4 webhook receivers.

**Findings: 10 — 5 HIGH, 5 MEDIUM. Resolution: 9 fixed, 1 mitigated.**
Each carries an OWASP category, `file:line`, and the fixing commit.

| Severity | Finding | Resolution |
|---|---|---|
| HIGH | `/auth/login` credential brute force | Rate limiting |
| HIGH | `/interview/start` code-validity oracle | Response normalisation |
| HIGH | Google OAuth tokens stored in plaintext | Encryption at rest |
| HIGH | Unpinned Python dependencies | Hash-pinned lockfile |
| MEDIUM | Wildcard CORS reachable in production | Surfaced as a boot warning |
| MEDIUM | Unbounded upload sizes | 5 MB / 8 MB caps |
| MEDIUM | OAuth state replay | Signed, expiring, single-use + nonce sweep |

Supply-chain hardening: third-party GitHub Actions pinned to commit SHAs; dependencies installed
from a hash-pinned lock rather than resolved at build time; `nanoid` bumped past
GHSA-2v37-7h3g-55p8; Next.js 14 → 15 and React 18 → 19.

---

## 7. Experimental verification

Model evaluation is documented in `DATASET.md`. Summary:

| Experiment | Held-out result |
|---|---|
| **Grounding gate (5,200 résumés)** | **100 % paraphrase rejection, 100 % negation-trap rejection, 100 % verbatim admission** |
| Sufficiency model (synthetic) | AUC 0.8515, ECE 0.0321 |
| Face threshold (LFW) | FAR 0.030 / FRR 0.034 @ 0.1266 |
| Résumé fit (HuggingFace) | AUC 0.6573 — reported as insufficient to deploy |

### The grounding harness (`service/eval/`)

An offline, deterministic, no-LLM-key harness drives the real pipeline modules read-only over 5,200
synthetic résumés — roughly 100,000 adversarial trials. It measures the project's central claim
rather than asserting it.

| Metric | Trials | Before | After |
|---|---|---|---|
| Verbatim true-positive rate | 51,761 | 99.18 % (425 rejected) | **100.00 %** |
| Paraphrase rejection | 48,149 | 100.00 % | **100.00 %** |
| Negation-trap rejection | 51,761 | 100.00 % | **100.00 %** |

```bash
cd service && ./.venv/Scripts/python.exe -m eval.harness --limit 5200 --out eval/metrics.json
```

**It found a real, silent bug.** All 425 false rejections contained a period-bearing token
(`Node.js`, `React.js`, `asp.net`, `Python 3.9`) and zero occurred without one: the clause splitter
read the `.` inside the token as a sentence terminal, so the claim spanned two clauses and could
never be located. Nothing crashed and no test failed — claims simply went missing. Fixed in
`grounding.py::_CLAUSE_BOUNDARY` with four regression tests, two of which assert the safety
properties survive.

This is the argument for corpus-scale evaluation alongside unit testing: a silent false-rejection is
invisible to tests that only exercise the paths you thought to write.

Both embedding caches are committed, so the face and résumé-fit results reproduce without re-running
the embedding models.

---

## 8. Running the suites

```bash
flutter test --exclude-tags=preview
```

```bash
service/.venv/Scripts/python.exe -m pytest -q
```

```bash
cd portal && npx vitest run
```

---

## 9. Honest gaps

1. **Portal coverage is one file, two tests.** The candidate-facing surface carries the least
   automated verification of any surface. This is the clearest testing gap in the project.
2. **No load testing.** Correctness is tested; behaviour under concurrent sessions is not.
3. **No end-to-end browser automation.** The full candidate journey is verified manually.
4. **Android untested.** The Flutter app is verified on Windows only.
