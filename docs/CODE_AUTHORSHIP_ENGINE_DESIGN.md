# Code Authorship Verification Engine — Design

Status: **design only, not implemented.** This is the concrete, code-specific
task-generation layer underneath `ADAPTIVE_INTERVIEW_ENGINE_DESIGN.md`: where
that engine decides *when* and *which dimension* to probe, this engine
decides *what actual task* to hand the candidate when the target is code.
It reuses `ProcessTelemetry.spansWorthProbing()`, the `EvidenceRequirement`
rubric from `CLAIM_EXTRACTION_DESIGN.md`, and emits into the
`EvidenceGraph` — it does not duplicate any of the three.

## What this measures, precisely

Not "did a human type this." Not "does this look like GPT output." Whether
**this specific person, right now, has a working mental model of this
specific code** — can explain its structure, predict what a change to it
does, reason about what it costs, and defend why it's shaped the way it is.
That property is unaffected by how the code was drafted. A tool-assisted
submission the candidate genuinely understands passes. A self-typed
submission copied from a tutorial without comprehension fails. Detecting the
drafting method is not just unreliable — it's not the thing this system was
ever supposed to measure.

## Explicit non-goals — the trap to design against

Each of these is the shortcut an implementation would reach for if "verify
authorship" gets misread as "verify no AI was involved." All excluded, for
the same reason: they measure the wrong variable, and most of them don't
even measure it reliably.

- **No AI-generated-code classifier, no stylometry, no "this looks like
  GPT" heuristic, no third-party AI-detection API call.** These have high
  false-positive rates even in their best-supported domain (prose); for code
  there is no comparable signal at all, since idiomatic AI-assisted code and
  idiomatic human code overlook the same conventions.
- **No comparison against "known AI assistant output patterns."** Same
  reasoning — and it invites an arms race with tool fingerprints instead of
  measuring the candidate.
- **No paste-origin detection, no clipboard monitoring.** Irrelevant to the
  actual question. A candidate pasting their own prior work, or code an
  assistant helped draft, is not the thing being checked.
- **No automated pass/fail on submitted code's correctness (tests passing,
  linter score) used as a hiring signal.** That's a different, legitimate
  measurement (does the code work) smuggled in as a proxy for understanding,
  which it is not — those are two separate things.

What replaces all of this: five probe types that can only be answered well
by someone who actually holds a working model of the specific code in front
of them, detailed below.

---

## Architecture

```
                 ┌───────────────────────────────┐
                 │ Claim + EvidenceRequirement      │  (Claim Extraction Engine)
                 └────────────────┬────────────────┘
                                  │
 ┌───────────────────┐  ┌────────▼─────────────────────┐
 │ ProcessTelemetry     │  │   ADAPTIVE INTERVIEW ENGINE      │
 │ .spansWorthProbing()  │─▶│   decides WHEN + WHICH dimension  │
 │ (existing, reused)     │  │   to probe next (existing design)  │
 └───────────────────┘  └────────┬─────────────────────┘
                                  │ "probe dimension D on claim C;
                                  │  code evidence available at span S"
                                  ▼
                 ┌─────────────────────────────────────┐
                 │       CODE AUTHORSHIP ENGINE (new)       │
                 │                                          │
                 │  Probe-type selector (dimension → type)   │
                 │  Authored libraries, closed and versioned: │
                 │    · mutation operators (bug tasks)         │
                 │    · alternative-technique lists (tradeoffs)│
                 │    · structural complexity-scan rules        │
                 │  Bounded LLM roles: SELECT from the library  │
                 │  and PHRASE against the candidate's actual    │
                 │  variable/function names. Never invent a new  │
                 │  operator, alternative, or complexity claim.   │
                 └─────────────────┬───────────────────────┘
                                   │ one concrete task/question
                                   ▼
                 ┌─────────────────────────────────┐
                 │   interview_screen.dart (existing)  │
                 │   displays it, collects response +   │
                 │   any resulting code diff              │
                 └─────────────────┬───────────────────┘
                                   │ response, new telemetry
                                   ▼
                 ┌─────────────────────────────────┐
                 │    EVIDENCE GRAPH (existing design)  │
                 │  codeEvidence / interviewAnswer nodes │
                 │  + supports / contradicts / probes     │
                 │  edges, each with a rationale            │
                 └─────────────────────────────────┘
```

**Shared generation principle, stated once because it applies to all five
probe types below:** every task is generated from (1) the candidate's
*actual* submitted code, never a generic template snippet, (2) the specific
`EvidenceDimension` currently targeted, and (3) an authored, closed library
of operators/patterns for that dimension. The LLM's role is bounded to
selecting which library entry fits this code and phrasing it against the
candidate's real names — the same "authored taxonomy, LLM only classifies
or phrases, never invents" discipline as Claim Extraction's claim-type table
and the Adaptive Interview Engine's template bank.

---

## The five probe types

### 1. Adaptive architectural questions (the baseline, always available)

What it tests: whether the candidate holds a structural model of *their own*
code, escalating with the interview engine's tier ladder — surface ("what
does this function do"), applied ("how does this fit with the read path"),
architectural ("what would you change to support 100x the write volume, and
why"). Grounded in the code's actual structure (real function/variable
names), never generic — "what is a distributed cache" is answerable by
anyone who's read about caches; "why does `invalidate` remove from `_lru`
before `_store` rather than after" is answerable only by someone who holds a
model of *this* code.

```dart
class ArchitecturalQuestion {
  final String claimId;
  final String targetSpanRef;   // codeEvidence node id it's grounded in
  final DepthTier tier;         // from the Adaptive Interview Engine
  final String dimensionKey;
  final String question;
}
```

### 2. Bug introduction tasks — two sub-modes, both disclosed

**Disclosure requirement, stated up front because it's the sharpest ethical
line in this document:** every bug-introduction task tells the candidate,
plainly, that it is a deliberate exercise — "here's a version of your code
with one intentional change" — never presented as if it were a real system
error or an organic bug. The existing adversarial-follow-up mechanism is
adversarial-but-fair precisely because it is never deceptive about its own
nature (`FollowUp.trigger`/`observation` are already shown to the candidate
on request). A silently swapped bug, undisclosed, crosses from a fair
comprehension test into a trap, and that line matters as much here as the
"never accuse" requirement did in the interview engine design.

**System-introduced (comprehension-under-change):** a deterministic mutation
operator, drawn from a closed authored library, is applied to a copy of the
candidate's actual code:

| Operator | What it does | Probes dimension |
|---|---|---|
| `ComparisonFlip` | `!=`↔`==`, `<`↔`<=` | Correctness / Consistency |
| `OffByOne` | shifts a loop bound or index by one | EdgeCases |
| `OrderSwap` | reorders two statements with an implicit ordering dependency | Consistency |
| `LockOrAwaitRemoval` | removes a lock/await, introducing a race | Consistency / Concurrency |
| `NullGuardRemoval` | removes a null/bounds check | EdgeCases |
| `ResourceCleanupRemoval` | removes a dispose/close/free call | Scaling / resource management |

Worked example, continuing this project's running distributed-cache claim:

```dart
// Candidate's actual submitted code:
Future<void> invalidate(String key) async {
  final entry = _store[key];
  if (entry != null) {
    _lru.remove(entry);
    _store.remove(key);
  }
}

// OrderSwap applied — probes Consistency:
Future<void> invalidate(String key) async {
  final entry = _store[key];
  if (entry != null) {
    _store.remove(key);
    _lru.remove(entry);   // now runs after the store entry is gone
  }
}
```

Question: *"Here's a version of `invalidate` with one intentional change.
What's different, and what could go wrong if another request read `_lru`
between these two lines now?"* Answering well requires having a genuine
mental model of the ordering dependency — not spotting a diff, predicting
its consequence.

**Candidate-introduced (deliberate breakage — arguably the sharper test):**
ask the candidate to make a specific, minimal, plausible change to their own
code that would break one particular property. *"Show me the smallest
change to `invalidate` that would cause a stale read — don't just say what,
make the edit."* A shallow understanding produces silence or a vague
non-answer; genuine understanding produces a precise, targeted edit, because
you have to understand the failure surface well enough to aim at it.

```dart
class BugIntroductionTask {
  final String claimId;
  final String mode;            // "systemIntroduced" | "candidateIntroduced"
  final String? mutationOperator;   // set when systemIntroduced
  final String originalSpanRef;
  final String? mutatedCode;        // set when systemIntroduced, LLM-validated
                                     // to still parse before display — see
                                     // Production Hardening
  final String dimensionKey;
  final String disclosureText;      // always shown, "this is a deliberate
                                     // exercise" — never optional
  final String question;
}
```

### 3. Code modification tasks

Ask the candidate to extend their own code live with a new requirement —
"add TTL-based expiration to this cache." This is a harder test than
after-the-fact explanation: you have to act correctly *within* the mental
model you claim to hold, under time pressure, not just describe it — the
same reasoning that already makes the existing adversarial follow-up work
("a materially harder task than producing it was"), one level up.

The task carries an authored `expectedTouchPoints` list — the
functions/data structures a genuine understanding would need to touch — but
this is **never auto-graded pass/fail**. It's a rubric for what the
*following* question asks about ("you didn't touch the LRU list when adding
expiration — walk me through why that's safe, if it is"), not an automated
correctness gate. Auto-grading code correctness as a hiring signal would be
the composite-score anti-pattern in a new outfit.

```dart
class CodeModificationTask {
  final String claimId;
  final String targetSpanRef;
  final String requirement;
  final List<String> expectedTouchPoints;   // rubric for the follow-up,
                                             // never a pass/fail gate
}
```

### 4. Complexity questions

Grounded in the actual data structures in the submitted code, not generic
Big-O trivia. The useful property here, unlike the other four: for **common,
recognizable patterns** — a single loop over a known-size collection, nested
loops, a hashmap/set lookup, a sorted-structure operation — a lightweight
structural scan of the code's control flow can derive a **reference
complexity mechanically**, no LLM guess required, to check the candidate's
stated answer against. This only covers common shapes honestly; genuinely
recursive, amortized, or data-dependent cases fall back to the same bounded
LLM judgment used elsewhere (see Production Hardening) — this is not claimed
to generalize to arbitrary code, which would be an overclaim in the same
family this project has been careful to avoid elsewhere (see the identity
threshold's "reasoned, not validated" framing).

```dart
class ComplexityQuestion {
  final String claimId;
  final String targetSpanRef;
  final String dimensionProbed;      // "time" | "space" | "scalingBehavior"
  final String? structuralReference;  // mechanically derived, when the
                                       // pattern is common enough — e.g.
                                       // "O(1) amortized: HashMap lookup +
                                       // direct-reference list removal"
  final String question;
}
```

### 5. Alternative solution questions

"Why this over that" — tests whether a choice was a deliberate tradeoff or
an arbitrary/copied one, since articulating a tradeoff requires knowing what
the alternative would have cost. The alternative isn't invented by the LLM
per call — it's drawn from an authored, per-domain list (tied to Claim
Extraction's taxonomy, so the same list serves both engines):

| Claim area | Authored alternatives |
|---|---|
| Cache eviction (`system_design`) | LRU, LFU, FIFO, random replacement, 2Q, ARC |
| Cache sharding (`system_design`) | consistent hashing, rendezvous hashing, static modulo sharding |
| Data structure choice | HashMap, sorted tree/skip list, trie — by access pattern |
| Concurrency primitive | lock, lock-free/CAS, actor/single-writer queue |

```dart
class AlternativeSolutionQuestion {
  final String claimId;
  final String targetDecisionPoint;   // e.g. "eviction policy"
  final String candidateChoice;       // as observed in the code, e.g. "LRU"
  final String plausibleAlternative;  // from the authored list above
  final String question;
}
```

---

## Probe-type selection — which dimension prefers which type

Authored mapping, not learned, mirroring every other selection table in
this project's design docs:

| `EvidenceDimension` | Preferred probe type(s) | Why |
|---|---|---|
| Architecture | Architectural question, or Code modification | Structural model, best shown by extending it |
| Scaling | Complexity question, or Code modification ("what changes at 10x") | Scaling is a complexity/behavior question by nature |
| Consistency | Bug introduction (`OrderSwap`, `LockOrAwaitRemoval`) | These are the canonical consistency-bug shapes |
| Technology | Alternative solution question | "Why this tech" is a direct tradeoff question |
| Tradeoffs | Alternative solution question, or Bug introduction | Tradeoffs are best shown by "what if you'd chosen differently" |
| EdgeCases (algorithm claims) | Bug introduction (`OffByOne`, `NullGuardRemoval`) | Edge-case bugs are exactly these operator categories |
| ComplexityCharacteristics (algorithm claims) | Complexity question | Direct match |

---

## Continuous evidence collection

Modeled as a stream, matching the existing reactive pattern already used by
`VerificationSession.results`/`onCritical` rather than a batch/polling
design:

```dart
abstract class CodeAuthorshipEngine {
  /// Fed by the SAME telemetry stream FollowUpGenerator already watches.
  /// Emits a new opportunity whenever a fresh probe-worthy span appears —
  /// the engine does not generate all five questions upfront and stop; it
  /// keeps watching for as long as the claim is being examined.
  Stream<ProbeOpportunity> opportunities(String claimId);
}

class ProbeOpportunity {
  final String claimId;
  final String dimensionKey;
  final String triggeringSpanRef;   // the codeEvidence span that opened this
  final List<String> eligibleProbeTypes;  // from the selection table above
}
```

Every task's outcome — the candidate's answer, any resulting code diff, the
telemetry around producing it — becomes `codeEvidence`/`interviewAnswer`
nodes and `supports`/`contradicts`/`probes` edges in the Evidence Graph,
exactly per that design's schema. This engine does not invent a separate
evidence store; it's one more producer into the same graph.

---

## Prompt templates (bounded roles only)

### Operator/alternative selection (choose from the closed library, never invent)

```
You are selecting which ONE item from a fixed list best fits a piece of
code, for a comprehension check. You are not writing new content yet, only
choosing.

CODE: {quoted_span}
DIMENSION BEING PROBED: {dimension.label} — {dimension.description}
AVAILABLE OPTIONS (choose exactly one, or "none_fit"):
{authored_list_for_this_dimension}

Return only: { "selected": "<option_key>" | "none_fit" }
```

### Mutation validity check (deterministic property, LLM only verifies it holds)

```
You are checking one factual property: does the MUTATED code below still
parse as valid {language} and remain structurally similar enough to the
ORIGINAL that a reader would recognize it as the same function with one
change — not a rewrite, not something that fails to compile.

ORIGINAL: {original_span}
MUTATED (operator: {operator_name}): {mutated_span}

Return only: { "valid": true | false, "reason": "..." }
```

A `false` result discards the mutation and either tries the next-ranked
operator from the library or falls back to a different probe type entirely
— a broken or nonsensical mutation is never shown to a candidate.

### Question phrasing (references the candidate's real names, never a template blank)

```
Write ONE question referencing the code below by its actual function and
variable names. Do not imply doubt about whether the candidate wrote it or
understands it — this is a request to explain or extend, not a challenge.

CODE: {quoted_span}
PROBE TYPE: {probe_type}
SELECTED LIBRARY ITEM: {selected_operator_or_alternative}
WHAT THEY'VE ALREADY SAID (build on it, don't repeat): {prior_answers_summary}

Return only: { "question": "..." }
```

(Passes the same structural linter from the Adaptive Interview Engine design
before display — no accusatory phrasing, forward-looking shape only.)

---

## Production hardening

- **Bug-introduction tasks have the strongest LLM-outage fallback of any
  probe type in this system.** Mutation operators are deterministic
  syntactic transforms — an operator can be applied and a basic parse-check
  run with zero LLM involvement at all. If the LLM is down, the engine can
  still pick an operator (round-robin or a fixed priority order per
  dimension, from the same authored table) and generate a template-phrased
  question ("here's a version of `{functionName}` with one change — what's
  different, and what would it do?") without any model call. This is
  strictly more robust than Claim Extraction or the Adaptive Interview
  Engine's fallback paths, and worth building first for that reason.
- **Complexity questions degrade gracefully too** — the structural-scan
  reference (common patterns) needs no LLM; only genuinely ambiguous cases
  need the bounded judgment call, and those can simply be skipped in favor
  of a different probe type during an outage.
- **Alternative-solution and architectural questions are the two probe
  types that most need the LLM** (phrasing against real code, referencing
  what was already said) — during an outage these fall back to the Adaptive
  Interview Engine's own template bank rather than going silent.
- **Mutations never reach the candidate unvalidated.** The parse/structural
  check above is a hard gate, not a best-effort pass — a mutation that fails
  it is discarded, never shown degraded.

---

## What's implementable today

The mutation-operator library (a set of real syntactic transforms per
language), the alternative-technique tables, the structural complexity-scan
rules for common patterns, the probe-type selection table, and the
stream-based `ProbeOpportunity` plumbing off existing telemetry are all
deterministic and testable right now — no LLM key needed. The three bounded
LLM roles (operator/alternative selection, mutation validity check, question
phrasing) are blocked on the same key already flagged across the other
designs. Given the fallback path above, this engine could plausibly ship a
useful (if less precisely targeted) version *before* an LLM key exists at
all — the mutation-based bug-introduction tasks work close to end-to-end
without one.
