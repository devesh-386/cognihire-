"""Saying hello to a live interview.

"Hi, this is Devesh here" used to be handed to `interview_session.answer()`
like any other utterance: analysed against a technical claim by a full LLM
call, judged unsupported because a greeting supports nothing, and charged
one of `_MAX_ATTEMPTS_PER_TOPIC`. A candidate who opened politely lost an
attempt on a topic before being asked about it once, and the recruiter's
report carried an "unsupported" verdict earned by saying hello.

It was also the slowest way to not answer — that analysis sat between the
candidate finishing their sentence and hearing anything at all.

Same shape as `_CLARIFICATION_PHRASES` before it, and the same risk: a gate
that is too eager stops a REAL answer from being graded, which is far worse
than missing a greeting. Most of these pin that boundary.
"""

from __future__ import annotations

import asyncio

from session.live_interview import _first_name, _is_greeting


def run(coro):
    return asyncio.run(coro)


class TestRecognisedAsGreetings:
    def test_bare_hello(self):
        assert _is_greeting("Hello")

    def test_the_reported_phrasing(self):
        assert _is_greeting("Hi, this is Devesh here")

    def test_self_introduction(self):
        assert _is_greeting("My name is Devesh and I'm here for the backend role")

    def test_time_of_day(self):
        assert _is_greeting("Good morning")

    def test_pleasantry(self):
        assert _is_greeting("Nice to meet you")

    def test_is_case_and_whitespace_insensitive(self):
        assert _is_greeting("   HELLO   ")

    def test_survives_a_smart_quote_from_transcription(self):
        assert _is_greeting("“Hi there")


class TestNotGreetings:
    """The half that matters more — a false positive silently drops a real
    answer out of grading, and the candidate is never asked again."""

    def test_an_answer_beginning_with_a_pleasantry_is_still_an_answer(self):
        assert not _is_greeting(
            "Hi, so the way I approached the migration was to shard by tenant "
            "id and run both stores in parallel for a fortnight before cutting over"
        )

    def test_hi_inside_a_word_does_not_match(self):
        assert not _is_greeting("Architecture was the part I owned")

    def test_this_is_mid_sentence_does_not_match(self):
        """'this is' is a greeting prefix and also how half of all technical
        answers begin. Anchoring is what separates them."""
        assert not _is_greeting("We sharded by tenant, and this is how it scaled")

    def test_a_long_self_introduction_that_is_really_an_answer(self):
        assert not _is_greeting(
            "I am the engineer who rewrote the ingestion pipeline in FastAPI, "
            "cut p99 latency from eight hundred milliseconds to ninety, and "
            "then moved the whole thing onto three regions"
        )

    def test_a_substantive_short_answer(self):
        assert not _is_greeting("We used Postgres with read replicas.")

    def test_empty(self):
        assert not _is_greeting("")


class TestFirstName:
    def test_takes_the_first_token(self):
        assert _first_name("devesh s v") == "Devesh"

    def test_title_cases_what_intake_stored(self):
        """Intake stores whatever was typed on the form; a greeting should
        not read as though it were shouted."""
        assert _first_name("DEVESH") == "Devesh"

    def test_single_name(self):
        assert _first_name("Priya") == "Priya"

    def test_missing_name_yields_none_not_a_crash(self):
        assert _first_name(None) is None
        assert _first_name("") is None
        assert _first_name("   ") is None


class TestGreetingBehaviour:
    """What the candidate actually hears, and what the report never sees."""

    @staticmethod
    def _orchestrator(monkeypatch, candidate_name="devesh s v"):
        import json

        from pipeline import supabase_store
        from session import live_interview, session_store

        class FakeWS:
            def __init__(self):
                self.sent: list[dict] = []

            async def send(self, raw):
                self.sent.append(json.loads(raw))

            async def send_text(self, raw):
                self.sent.append(json.loads(raw))

        async def fake_fetch_session(_session_id):
            return {
                "id": "session-1",
                "candidate_id": "cand-1",
                "status": "in_progress",
                "current_topic": "FastAPI",
                "last_question": "Tell me about FastAPI.",
                "coverage_state": {"completion_percent": 0},
                "question_plan": {},
            }

        async def fake_fetch_candidate(_candidate_id):
            return {"id": "cand-1", "name": candidate_name}

        def fake_current_turn(_row):
            return {"kind": "question", "topic": "FastAPI", "question": "Tell me about FastAPI."}

        async def must_not_grade(*_a, **_k):
            raise AssertionError("a greeting must never reach answer()")

        async def allow(*_a, **_k):
            return None

        monkeypatch.setattr(session_store, "fetch_session", fake_fetch_session)
        monkeypatch.setattr(supabase_store, "fetch_candidate", fake_fetch_candidate)
        monkeypatch.setattr(live_interview.interview_session, "current_turn", fake_current_turn)
        monkeypatch.setattr(live_interview.interview_session, "answer", must_not_grade)
        monkeypatch.setattr(live_interview, "authorize", allow)

        openai_ws, candidate_ws = FakeWS(), FakeWS()
        orch = live_interview.LiveOrchestrator.__new__(live_interview.LiveOrchestrator)
        orch.openai_ws = openai_ws
        orch.candidate_ws = candidate_ws
        orch.session_id = "session-1"
        orch.code = "CODE1234"
        return orch, openai_ws

    @staticmethod
    def _spoken(openai_ws):
        out = []
        for msg in openai_ws.sent:
            if msg.get("type") != "response.create":
                continue
            for item in msg["response"].get("input", []):
                for part in item.get("content", []):
                    out.append(part.get("text", ""))
        return out

    def test_greets_the_candidate_by_their_own_name(self, monkeypatch):
        orch, openai_ws = self._orchestrator(monkeypatch)

        run(orch._on_candidate_utterance("Hi, this is Devesh here"))

        assert "Hi Devesh, nice to meet you." in self._spoken(openai_ws)

    def test_repeats_the_pending_question_after_greeting(self, monkeypatch):
        """Otherwise a greeting leaves the candidate in silence, waiting on
        a question that already went by."""
        orch, openai_ws = self._orchestrator(monkeypatch)

        run(orch._on_candidate_utterance("Hello"))

        assert self._spoken(openai_ws) == [
            "Hi Devesh, nice to meet you.",
            "Tell me about FastAPI.",
        ]

    def test_a_greeting_never_reaches_grading(self, monkeypatch):
        """The bug: it did — spending an attempt and writing an unsupported
        verdict into the recruiter's report. `answer` is stubbed to raise,
        so reaching it fails this test."""
        orch, _openai_ws = self._orchestrator(monkeypatch)

        run(orch._on_candidate_utterance("Good morning"))

    def test_an_unreadable_name_still_gets_a_greeting(self, monkeypatch):
        """The candidate said hello and deserves an answer either way —
        better a nameless greeting than falling through to grading one."""
        orch, openai_ws = self._orchestrator(monkeypatch, candidate_name=None)

        run(orch._on_candidate_utterance("Hi"))

        assert "Hi, nice to meet you." in self._spoken(openai_ws)
