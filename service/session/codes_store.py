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
