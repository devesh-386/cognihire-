"""Supabase access for interview_sessions / interview_events.

Same pattern as `pipeline/supabase_store.py`: service-role key, REST calls,
never raises for a "not found" (returns None) but raises `SupabaseError` when
the database itself could not be reached — this module must never claim a
write succeeded when it did not.
"""

from __future__ import annotations

import httpx

from pipeline.supabase_store import SUPABASE_SERVICE_ROLE_KEY, SUPABASE_URL, SupabaseError

_TIMEOUT = 30


def _headers() -> dict[str, str]:
    if not SUPABASE_URL or not SUPABASE_SERVICE_ROLE_KEY:
        raise SupabaseError(
            "SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set for session storage"
        )
    return {
        "apikey": SUPABASE_SERVICE_ROLE_KEY,
        "Authorization": f"Bearer {SUPABASE_SERVICE_ROLE_KEY}",
        "Content-Type": "application/json",
    }


async def create_session(fields: dict) -> dict:
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.post(
            f"{SUPABASE_URL}/rest/v1/interview_sessions",
            headers={**_headers(), "Prefer": "return=representation"},
            json=fields,
        )
    if response.status_code not in (200, 201):
        raise SupabaseError(f"session create failed: HTTP {response.status_code} {response.text[:200]}")
    rows = response.json()
    return rows[0]


async def fetch_session(session_id: str) -> dict | None:
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.get(
            f"{SUPABASE_URL}/rest/v1/interview_sessions",
            headers=_headers(),
            params={"id": f"eq.{session_id}", "select": "*"},
        )
    if response.status_code != 200:
        raise SupabaseError(f"session lookup failed: HTTP {response.status_code}")
    rows = response.json()
    return rows[0] if rows else None


async def update_session(session_id: str, fields: dict) -> None:
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.patch(
            f"{SUPABASE_URL}/rest/v1/interview_sessions",
            headers=_headers(),
            params={"id": f"eq.{session_id}"},
            json=fields,
        )
    if response.status_code not in (200, 204):
        raise SupabaseError(f"session update failed: HTTP {response.status_code} {response.text[:200]}")


async def append_event(event: dict) -> None:
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.post(
            f"{SUPABASE_URL}/rest/v1/interview_events",
            headers=_headers(),
            json=event,
        )
    if response.status_code not in (200, 201):
        raise SupabaseError(f"event append failed: HTTP {response.status_code} {response.text[:200]}")


async def list_events(session_id: str) -> list[dict]:
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.get(
            f"{SUPABASE_URL}/rest/v1/interview_events",
            headers=_headers(),
            params={"session_id": f"eq.{session_id}", "select": "*", "order": "sequence.asc"},
        )
    if response.status_code != 200:
        raise SupabaseError(f"event list failed: HTTP {response.status_code}")
    return response.json()


async def list_sessions_for_org(organization_id: str, *, status: str | None = None) -> list[dict]:
    """Powers the portal's Interviews and Reports lists. `status` filters to
    e.g. "complete" for Reports — same table, different view, so this stays
    one query rather than a second store function to keep in sync."""
    params = {
        "organization_id": f"eq.{organization_id}", "select": "*", "order": "created_at.desc",
    }
    if status is not None:
        params["status"] = f"eq.{status}"
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.get(
            f"{SUPABASE_URL}/rest/v1/interview_sessions",
            headers=_headers(),
            params=params,
        )
    if response.status_code != 200:
        raise SupabaseError(f"session list failed: HTTP {response.status_code}")
    return response.json()


async def next_sequence(session_id: str) -> int:
    """The next event sequence number for a session — count of events so far."""
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.get(
            f"{SUPABASE_URL}/rest/v1/interview_events",
            headers={**_headers(), "Prefer": "count=exact"},
            params={"session_id": f"eq.{session_id}", "select": "sequence", "limit": 1},
        )
    # PostgREST answers 206 Partial Content (not 200) whenever `limit` caps
    # the result below what actually matched — which `limit=1` here always
    # does once a session has more than one event. Never caught by the test
    # suite's fake, which only ever returned 200; found live against real
    # Supabase (Ticket 21 rollout) where every second answer in an interview
    # failed with "event count failed: HTTP 206".
    if response.status_code not in (200, 206):
        raise SupabaseError(f"event count failed: HTTP {response.status_code}")
    content_range = response.headers.get("content-range", "*/0")
    total = content_range.split("/")[-1]
    return int(total) if total.isdigit() else 0
