# The prompt layer for the live interviewer

This directory is the *reasoning contract* for the real-time interviewer. It
holds no transport code: LiveKit, Whisper, Kokoro, and the face service are
plumbing, and none of them need a prompt. Only three things in the proposed
six-agent design are language-model work, and each one gets a file here.

| Proposed agent | What it actually is | Lives in |
|---|---|---|
| Voice | streaming STT + TTS + barge-in. Deterministic. | transport, not here |
| Vision | CV model emitting numbers. Deterministic. | `lib/core/verification/` |
| Resume | claim extraction under the verbatim gate. **Already built.** | `lib/core/claims/ollama_claim_extractor.dart` |
| Interview | decides the next spoken turn | `interview_agent.v2.txt` |
| Scoring | scores one answer against one assertion | `scoring_agent.txt` |
| Report | writes the recruiter's summary | `report_agent.txt` |

Calling the first two "agents" is the one part of the sketch I would drop. An
agent implies judgement; a face-landmark tracker has none. Naming them agents is
how a system starts letting a jitter number become "low confidence".

## The load-bearing decision: `say` serialises first

The interviewer has to start speaking before it has finished thinking, or it
sounds broken. Standard practice — reason first, answer last — is exactly wrong
here: it puts the entire reasoning trace between the candidate's silence and the
first spoken syllable.

So the turn object emits `say` as its **first key**, and the stream parser
forwards those characters to TTS while the model is still writing `quote`,
`difficulty_delta`, and `why`. The audit fields arrive free, during speech that
is already playing. `run_eval.py` enforces the key order, because a model that
reorders the object silently converts this design back into a latency bug.

The corollary: no chain-of-thought in this prompt. `why` is a one-sentence
post-hoc note for the recruiter's trail, not a scratchpad the model reasons in.
If a turn needs real deliberation, that is a signal to lower `max_iterations`
work, not to add thinking tokens ahead of the audio.

## The grounding gate, extended to speech

`OllamaClaimExtractor` already refuses to let the model *author* a claim — it may
only *select* text present in the resume. The interviewer inherits that rule at
`quote`: a turn that says "you mentioned Kafka" must carry the candidate's own
words containing Kafka, copied character for character out of the transcript.
Cannot find them? Then it was never said, `kind` becomes `newtopic`, and `quote`
is empty.

This is the single highest-value assertion in the eval set
(`no-fabricated-quote`), because the failure it prevents — an AI interviewer
telling a recruiter that a candidate said something they did not — is the worst
output this system can produce, and it is the *most likely* fabrication for a 7B
model to produce, since the resume is right there in the context window.

`verbatim-quote-not-tidied` pins the ugly half of the same rule: when someone
says "we was putting them in s3", the quote keeps the grammar. A model that
tidies quotes is a model that edits people.

## Where I deviate from the live-state dashboard

The sketch's live panel includes `Confidence 82%`, `Stress Level 45%`, and
`Eye Contact 78%`, and feeds them back into question selection. I did not wire
those into the reasoning layer, and rule 5 of `interview_agent.v2.txt` forbids
the model from inferring or mentioning affect at all.

Three reasons, in the order that matters:

1. **CogniHire's whole thesis is "evidence graph, no hidden score."** A stress
   percentage that silently changes which questions a candidate is asked *is* a
   hidden score, and one the candidate can neither see nor contest.
2. **It is the part a reviewer will attack first, and they will be right.**
   Inferring emotion from face video has no defensible accuracy on a diverse
   candidate pool, and it maps directly onto disability, neurodivergence, and
   cultural difference in expression. `isValidatedOnRealData=false` applies here
   with far more force than it does to the ML engine.
3. **The adaptive behaviour you actually want does not need it.** Every adaptive
   move in the sketch is reachable from what the candidate *said*:
   `difficulty_delta` rises on a named tradeoff, number, or failure; it falls on
   "I don't know" or two short answers; brief answers get probed. That is
   observable, quotable, and defensible in a rejection conversation.

The vision signals stay in the product — recorded, timestamped, shown to the
human reviewer as raw signals. They just do not get a vote on the questions.
`no-emotion-inference` is the regression test.

## Eval gate

```bash
cd prompts/evals && python run_eval.py --eval interview_agent_eval.json --responses responses.json
```

15 cases, one per rule plus the two grounding cases. Every assertion is
mechanical — substring containment, enum membership, integer equality, word
count — so there is no model-judging-a-model in the gate.
`responses.example.json` holds hand-authored target outputs and scores 15/15; it
doubles as the contrastive example pool if a real model clusters failures on a
case. A missing case counts as a failure, never a skip.

Capture `responses.json` by running each case's inputs through Ollama with
`interview_agent.v2.txt` as the system prompt and `format: json`, keyed by case
id. The gate deliberately takes a file rather than calling Ollama itself, so it
runs in CI on a machine with no model.

## Structural baseline

`interview_agent.v1.txt` is the naive first draft, kept as the recorded
baseline (`evals/baseline.json`). v2 against it:

| | v1 | v2 |
|---|---|---|
| Clarity | 64 | **92** |
| Tokens | 461 | 626 |
| Ambiguity issues | 6 | 0 |

**The skill's structural gate fails, deliberately.** It requires tokens ≤ 110% of
baseline and v2 is at 136%. The waiver: this prompt is a static prefix reused
across every turn of an interview (~40 calls), served locally by Ollama with
`keep_alive` holding the prefill, so the prefix is amortised to roughly nothing
and is not billed at all. The budget that governs a spoken turn is the
*variable* part — transcript window, claims, state — which is why
`agents.json` caps `window_turns` at 6 rather than passing the whole transcript.
Spending 165 tokens of fixed prefix to delete six ambiguous instructions is the
right trade here; on a metered per-call API it would not be.

The two remaining redundancy flags on v2 are the repeated phrases "the last
answer" and "under 15 words" across rules 3 and 4. Both are load-bearing: those
rules are read independently, and deduplicating them into a shared clause is how
a model comes to apply one rule's threshold to the other.

## Files

- `interview_agent.v1.txt` — naive baseline, kept for comparison only
- `interview_agent.v2.txt` — the live turn prompt
- `scoring_agent.txt` — per-answer rubric; delivery is explicitly not evidence
- `report_agent.txt` — recruiter summary; emits no overall score by construction
- `schemas/interview_turn.schema.json` — turn contract, key order significant
- `agents.json` — turn-loop tool wiring (validated, no warnings)
- `evals/` — eval set, runner, reference fixture, structural baselines
