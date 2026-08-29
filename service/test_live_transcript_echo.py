"""The candidate's own words, echoed back during a live voice interview.

In the typed path a candidate watches their answer appear in the textarea
as they speak it. In live voice the screen showed nothing they had said, so
a misheard answer was indistinguishable from a correctly heard one until
the report — by which point the interview is over. Speaking into a screen
that never acknowledges you is also what made the live channel feel less
conversational than the typed fallback it was meant to improve on.

These pin the two halves that matter: the echo is sent, and it is display
only — it must never change what gets graded.

Follows test_live_interview.py's convention: a sync test driving one
coroutine through `run`, rather than adding a pytest-asyncio dependency
this suite does not otherwise use.
"""

from __future__ import annotations

import asyncio
import json

from session import live_interview


def run(coro):
    return asyncio.run(coro)


class FakeCandidateWS:
    def __init__(self):
        self.sent_text: list[dict] = []

    async def send_text(self, raw: str) -> None:
        self.sent_text.append(json.loads(raw))


def _relay():
    """An orchestrator with only the attribute the echo path touches.

    Deliberately not a fully constructed orchestrator: the point of this method is
    that it reaches nothing except the candidate socket, and building one
    with a session, a code and an OpenAI connection would hide that.
    """
    ws = FakeCandidateWS()
    relay = live_interview.LiveOrchestrator.__new__(live_interview.LiveOrchestrator)
    relay.candidate_ws = ws
    return relay, ws


def _echoes(ws: FakeCandidateWS) -> list[str]:
    return [m["text"] for m in ws.sent_text if m.get("type") == "candidate_transcript"]


def test_a_spoken_answer_is_echoed_back():
    relay, ws = _relay()

    run(relay._echo_candidate_transcript("We ran Kubernetes across three regions."))

    assert _echoes(ws) == ["We ran Kubernetes across three regions."]


def test_vad_noise_is_not_echoed():
    """A stray sound finalizes into one character. Flashing that on screen
    reads to the candidate as though they said it."""
    relay, ws = _relay()

    run(relay._echo_candidate_transcript("a"))

    assert _echoes(ws) == []


def test_a_clarification_request_is_echoed():
    """Deliberately NOT filtered the way the grading path filters it. The
    candidate really said this, and seeing it is how they know the system
    heard them ask rather than ignored them."""
    relay, ws = _relay()

    run(relay._echo_candidate_transcript("Sorry, could you repeat that?"))

    assert _echoes(ws) == ["Sorry, could you repeat that?"]


def test_the_echo_is_trimmed():
    relay, ws = _relay()

    run(relay._echo_candidate_transcript("   I led the migration.   "))

    assert _echoes(ws) == ["I led the migration."]


def test_the_echo_carries_no_grading_signal():
    """Display only: one message, one type, one field. If this ever grew a
    verdict, a score, or a coverage number, the candidate would be reading
    their own assessment mid-interview — which ED-14 (evidence is separate
    from disposition) exists to prevent anywhere it could reach them."""
    relay, ws = _relay()

    run(relay._echo_candidate_transcript("A substantive answer about sharding."))

    assert ws.sent_text == [
        {"type": "candidate_transcript", "text": "A substantive answer about sharding."}
    ]
