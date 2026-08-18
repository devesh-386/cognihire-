"""Regression test for how an event's `sequence` is allocated.

It used to be chosen by the service — read the count of a session's events,
insert count+1 — which is a read-then-write against a column carrying
`unique (session_id, sequence)`. Concurrent writers on one session read the
same count and the loser's insert died on the constraint, surfacing as HTTP
503 from `/interview/event`. Live symptom: the candidate portal fires its
tab/window/fullscreen signals as concurrent fire-and-forget POSTs, so bursts
of them lost every event but the first, silently (the client swallows those
failures) — losing exactly the behavior evidence the report is built from.

Allocation now lives in the database (migration 0011's BEFORE INSERT trigger,
serialized per session by an advisory lock). These tests pin the service side
of that contract: it must OMIT `sequence` so the trigger fills it, and must
stay correct when several events for one session are written at once.
"""

from __future__ import annotations

import asyncio

import pytest

from session import interview_session, session_store
from session.events import EventType, SessionEvent


def test_to_dict_omits_sequence_so_the_database_assigns_it():
    event = SessionEvent("session-1", EventType.TAB_HIDDEN, {})
    assert "sequence" not in event.to_dict()


def test_to_dict_keeps_an_explicitly_supplied_sequence():
    """Backfills and replays still get to say which slot a row belongs in;
    the trigger only fills a sequence that was left unset."""
    event = SessionEvent("session-1", EventType.TAB_HIDDEN, {}, sequence=7)
    assert event.to_dict()["sequence"] == 7


class _FakeStore:
    """Stands in for Supabase, including the trigger's job of allocating
    `sequence`, and enforces `unique (session_id, sequence)` the way the real
    table does — so a service that went back to choosing its own numbers
    would fail here instead of only in production."""

    def __init__(self):
        self.events: list[dict] = []

    async def fetch_session(self, session_id):
        return {"id": session_id, "status": "in_progress"}

    async def append_event(self, event):
        # Yield before allocating, not during it: the point of interleaving
        # here is to let a second caller reach this write while the first is
        # in flight — which is what broke the old count-then-insert. The
        # allocate-and-append below stays uninterrupted because the real
        # trigger holds a per-session advisory lock across exactly that.
        await asyncio.sleep(0)
        event = dict(event)
        if event.get("sequence") is None:
            event["sequence"] = 1 + max(
                [e["sequence"] for e in self.events
                 if e["session_id"] == event["session_id"]] or [0]
            )
        taken = {(e["session_id"], e["sequence"]) for e in self.events}
        if (event["session_id"], event["sequence"]) in taken:
            raise AssertionError(
                f"duplicate sequence {event['sequence']} for {event['session_id']}"
            )
        self.events.append(event)


@pytest.fixture
def fake_store(monkeypatch):
    store = _FakeStore()
    monkeypatch.setattr(session_store, "fetch_session", store.fetch_session)
    monkeypatch.setattr(session_store, "append_event", store.append_event)
    return store


def test_concurrent_events_on_one_session_all_persist(fake_store):
    """The portal's real pattern: opening devtools raises `blur` and
    `visibilitychange` together, each sent without awaiting the other."""
    signals = [
        EventType.WINDOW_BLUR, EventType.TAB_HIDDEN, EventType.FULLSCREEN_EXIT,
        EventType.TAB_VISIBLE, EventType.WINDOW_FOCUS, EventType.CONNECTION_LOST,
    ]

    async def scenario():
        await asyncio.gather(*(
            interview_session.record_event("session-1", signal, {})
            for signal in signals
        ))

    asyncio.run(scenario())

    assert len(fake_store.events) == len(signals)
    sequences = sorted(e["sequence"] for e in fake_store.events)
    assert sequences == list(range(1, len(signals) + 1))
