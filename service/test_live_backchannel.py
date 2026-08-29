"""The "mm-hmm" a live interview gives while it is still thinking.

`interview_session.answer()` runs a full LLM analysis before there is a next
question to speak. Until this existed, the candidate finished a sentence and
then heard several seconds of nothing, every single time — which is what
made the live channel feel like dictation into a form rather than a
conversation with a person.

The backchannel goes out the instant the transcript lands, before the
analysis starts, so the pause is filled while the real work happens behind
it.

What these pin hardest is what the acknowledgement must NOT contain. "Mm-hmm"
says *I heard you*. "Great answer" would say *I rated you* — a disposition,
expressed to the candidate, mid-interview, which is the one thing ED-14 and
ED-46 exist to keep out of this system.
"""

from __future__ import annotations

import asyncio
import json

import pytest

from session import codes_store, interview_session, live_interview


def run(coro):
    return asyncio.run(coro)


class FakeOpenAIWS:
    def __init__(self):
        self.sent: list[dict] = []

    async def send(self, raw):
        self.sent.append(json.loads(raw))


class FakeCandidateWS:
    def __init__(self):
        self.sent_text: list[dict] = []
        self.sent_bytes: list[bytes] = []

    async def send_text(self, raw):
        self.sent_text.append(json.loads(raw))

    async def send_bytes(self, data):
        self.sent_bytes.append(data)


def _orchestrator(monkeypatch, *, question="Tell me about caching."):
    order: list[str] = []

    async def fake_answer(session_id, answer_text, provider_override=None):
        order.append("analysis")
        return {
            "session_id": session_id,
            "turn": {"kind": "question", "topic": "caching", "question": question},
            "coverage": {},
            "analysis": {},
        }

    async def fake_fetch_by_code(code):
        return {"code": code, "session_id": "sess-1"}

    monkeypatch.setattr(codes_store, "fetch_by_code", fake_fetch_by_code)
    monkeypatch.setattr(interview_session, "answer", fake_answer)
    openai_ws = FakeOpenAIWS()
    orch = live_interview.LiveOrchestrator(
        FakeCandidateWS(), openai_ws, "sess-1", "CODE1",
    )
    return orch, openai_ws, order


def _spoken(openai_ws) -> list[str]:
    return [
        msg["response"]["input"][0]["content"][0]["text"]
        for msg in openai_ws.sent
        if msg.get("type") == "response.create"
    ]


def test_the_candidate_hears_something_before_the_analysis_runs(monkeypatch):
    """The point of the whole change: acknowledgement first, LLM second."""
    orch, openai_ws, order = _orchestrator(monkeypatch)

    original_speak = orch.speak

    async def tracking_speak(text):
        order.append(f"speak:{text}")
        await original_speak(text)

    orch.speak = tracking_speak

    run(orch._on_candidate_utterance("We used Redis with a write-through cache."))

    assert order[0] == "speak:Mm-hmm."
    assert order[1] == "analysis"


def test_the_next_question_follows_on_a_bridge_phrase(monkeypatch):
    orch, openai_ws, _ = _orchestrator(monkeypatch)

    run(orch._on_candidate_utterance("We used Redis with a write-through cache."))

    assert _spoken(openai_ws) == ["Mm-hmm.", "Thanks. Tell me about caching."]


def test_the_question_text_itself_is_never_rewritten(monkeypatch):
    """The bridge is a scripted prefix. The question still comes from the
    grounded state machine, word for word — if this ever became a
    paraphrase, the model would be authoring interview content."""
    orch, openai_ws, _ = _orchestrator(
        monkeypatch, question="Which parts of the schema did you own?",
    )

    run(orch._on_candidate_utterance("I rewrote the ingestion pipeline."))

    assert _spoken(openai_ws)[-1].endswith("Which parts of the schema did you own?")


def test_acknowledgements_rotate_rather_than_repeat(monkeypatch):
    """Identical noise after every answer is what makes canned
    acknowledgement sound canned."""
    orch, openai_ws, _ = _orchestrator(monkeypatch)

    run(orch._on_candidate_utterance("First answer about caching."))
    run(orch._on_candidate_utterance("Second answer about caching."))
    run(orch._on_candidate_utterance("Third answer about caching."))

    backchannels = [t for t in _spoken(openai_ws) if t in live_interview._BACKCHANNELS]
    assert backchannels == ["Mm-hmm.", "I see.", "Right."]


def test_bridges_rotate_independently_of_backchannels(monkeypatch):
    """A backchannel spoken between two questions must not shift which
    bridge comes next — they are separate rotations."""
    orch, openai_ws, _ = _orchestrator(monkeypatch)

    run(orch._on_candidate_utterance("First answer about caching."))
    run(orch._on_candidate_utterance("Second answer about caching."))

    bridges = [t.split(" ")[0] for t in _spoken(openai_ws) if "caching" in t]
    assert bridges == ["Thanks.", "Understood."]


@pytest.mark.parametrize("phrase", live_interview._BACKCHANNELS + live_interview._QUESTION_BRIDGES)
def test_no_acknowledgement_appraises_the_candidate(phrase):
    """The line this feature must not cross. An interviewer that tells a
    candidate their answer was good has expressed a disposition to them
    mid-interview — the thing this product promises it does not do.

    Checked as data rather than left to review, because the tempting fix
    for "make it warmer" is to add exactly one of these words.
    """
    appraisal = (
        "great", "good", "excellent", "impressive", "amazing", "wow",
        "strong", "weak", "perfect", "brilliant", "well done", "nice work",
        "fantastic", "poor", "better", "best",
    )
    lowered = phrase.lower()
    assert not any(word in lowered for word in appraisal), phrase


def test_a_backchannel_failure_never_stops_the_interview(monkeypatch):
    """A missing "mm-hmm" is a worse-feeling interview. An exception here
    would be no interview at all."""
    orch, openai_ws, _ = _orchestrator(monkeypatch)

    calls = {"n": 0}
    original_speak = orch.speak

    async def flaky_speak(text):
        calls["n"] += 1
        if calls["n"] == 1:
            raise RuntimeError("socket hiccup")
        await original_speak(text)

    orch.speak = flaky_speak

    run(orch._on_candidate_utterance("We used Redis with a write-through cache."))

    # The backchannel was lost, the question still got asked.
    assert _spoken(openai_ws) == ["Thanks. Tell me about caching."]
