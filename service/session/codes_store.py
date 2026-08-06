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
