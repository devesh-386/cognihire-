"""Supabase access for interview_codes. Same shape as session_store.py."""

from __future__ import annotations

import httpx

from pipeline.supabase_store import SUPABASE_SERVICE_ROLE_KEY, SUPABASE_URL, SupabaseError

_TIMEOUT = 30


def _headers() -> dict[str, str]:
    if not SUPABASE_URL or not SUPABASE_SERVICE_ROLE_KEY:
        raise SupabaseError(
            "SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set for interview codes"
        )
    return {
        "apikey": SUPABASE_SERVICE_ROLE_KEY,
        "Authorization": f"Bearer {SUPABASE_SERVICE_ROLE_KEY}",
        "Content-Type": "application/json",
    }


async def create_code(fields: dict) -> dict:
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.post(
            f"{SUPABASE_URL}/rest/v1/interview_codes",
            headers={**_headers(), "Prefer": "return=representation"},
            json=fields,
        )
    if response.status_code not in (200, 201):
        raise SupabaseError(f"code create failed: HTTP {response.status_code} {response.text[:200]}")
    return response.json()[0]


async def fetch_by_code(code: str) -> dict | None:
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.get(
            f"{SUPABASE_URL}/rest/v1/interview_codes",
            headers=_headers(),
            params={"code": f"eq.{code}", "select": "*"},
        )
    if response.status_code != 200:
        raise SupabaseError(f"code lookup failed: HTTP {response.status_code}")
    rows = response.json()
    return rows[0] if rows else None


async def fetch_by_id(code_id: str) -> dict | None:
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.get(
            f"{SUPABASE_URL}/rest/v1/interview_codes",
            headers=_headers(),
            params={"id": f"eq.{code_id}", "select": "*"},
        )
    if response.status_code != 200:
        raise SupabaseError(f"code lookup by id failed: HTTP {response.status_code}")
    rows = response.json()
    return rows[0] if rows else None


async def list_codes_for_org(organization_id: str) -> list[dict]:
    """Powers the portal's Interviews list' email-status column. Plain
    per-org scan, same shape as `session_store.list_sessions_for_org` —
    email status is attached by the caller (`main.py`), not here, to keep
    this module's job limited to `interview_codes` the way every other list
    function in this file already is."""
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.get(
            f"{SUPABASE_URL}/rest/v1/interview_codes",
            headers=_headers(),
            params={"organization_id": f"eq.{organization_id}", "select": "*", "order": "created_at.desc"},
        )
    if response.status_code != 200:
        raise SupabaseError(f"code list failed: HTTP {response.status_code}")
    return response.json()


async def fetch_by_session(session_id: str) -> dict | None:
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.get(
            f"{SUPABASE_URL}/rest/v1/interview_codes",
            headers=_headers(),
            params={"session_id": f"eq.{session_id}", "select": "*"},
        )
    if response.status_code != 200:
        raise SupabaseError(f"code lookup by session failed: HTTP {response.status_code}")
    rows = response.json()
    return rows[0] if rows else None


async def find_live_code_for_candidate(candidate_id: str) -> dict | None:
    """The auto-invite endpoint's idempotency check: the most recent code for
    this candidate that still means something, or None.

    Deliberately matches `used` as well as `active`. A completed interview
    flips its code to `used` (see `interview_session.finish`), so an
    active-only lookup would find nothing for someone who has already sat
    their interview — and auto-invite would cheerfully mint them a second
    code and email them again. `revoked`/`expired` are excluded because those
    genuinely should be replaceable. Expiry of an `active` row is the
    caller's call, since this module has no notion of "now"."""
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.get(
            f"{SUPABASE_URL}/rest/v1/interview_codes",
            headers=_headers(),
            params={
                "candidate_id": f"eq.{candidate_id}",
                "status": "in.(active,used)",
                "select": "*",
                "order": "created_at.desc",
                "limit": "1",
            },
        )
    if response.status_code != 200:
        raise SupabaseError(f"active code lookup failed: HTTP {response.status_code}")
    rows = response.json()
    return rows[0] if rows else None


async def update_code(code_id: str, fields: dict) -> None:
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.patch(
            f"{SUPABASE_URL}/rest/v1/interview_codes",
            headers=_headers(),
            params={"id": f"eq.{code_id}"},
            json=fields,
        )
    if response.status_code not in (200, 204):
        raise SupabaseError(f"code update failed: HTTP {response.status_code} {response.text[:200]}")


async def claim_code(code_id: str, expected_attempts_used: int, new_attempts_used: int) -> bool:
    """Atomic compare-and-swap: bumps `attempts_used` only if the row still
    has no session AND `attempts_used` still matches what the caller last
    read. A single PostgREST PATCH is one SQL UPDATE, so the WHERE clause
    (`session_id=is.null&attempts_used=eq.<expected>`) is evaluated and
    applied atomically at the database — no separate read-then-write gap for
    a second, concurrent redemption of the same code to land in.

    Returns True if this call won the race (the row matched and was
    updated), False if it lost (another request already claimed the code
    first) — the caller is expected to re-fetch and treat a loss as "someone
    else is already starting this session."
    """
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.patch(
            f"{SUPABASE_URL}/rest/v1/interview_codes",
            headers={**_headers(), "Prefer": "return=representation"},
            params={
                "id": f"eq.{code_id}",
                "session_id": "is.null",
                "attempts_used": f"eq.{expected_attempts_used}",
            },
            json={"attempts_used": new_attempts_used},
        )
    if response.status_code not in (200, 204):
        raise SupabaseError(f"code claim failed: HTTP {response.status_code} {response.text[:200]}")
    return bool(response.json())
