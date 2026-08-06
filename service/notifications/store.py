"""Supabase access for `interview_code_emails`. Same shape as
`session/codes_store.py`."""

from __future__ import annotations

import httpx

from pipeline.supabase_store import SUPABASE_SERVICE_ROLE_KEY, SUPABASE_URL, SupabaseError

_TIMEOUT = 30


def _headers() -> dict[str, str]:
    if not SUPABASE_URL or not SUPABASE_SERVICE_ROLE_KEY:
        raise SupabaseError(
            "SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set for interview code emails"
        )
    return {
        "apikey": SUPABASE_SERVICE_ROLE_KEY,
        "Authorization": f"Bearer {SUPABASE_SERVICE_ROLE_KEY}",
        "Content-Type": "application/json",
    }


async def find(code_id: str, email_type: str) -> dict | None:
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.get(
            f"{SUPABASE_URL}/rest/v1/interview_code_emails",
            headers=_headers(),
            params={"code_id": f"eq.{code_id}", "email_type": f"eq.{email_type}", "select": "*"},
        )
    if response.status_code != 200:
        raise SupabaseError(f"email lookup failed: HTTP {response.status_code}")
    rows = response.json()
    return rows[0] if rows else None


async def list_for_code(code_id: str) -> list[dict]:
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.get(
            f"{SUPABASE_URL}/rest/v1/interview_code_emails",
            headers=_headers(),
            params={"code_id": f"eq.{code_id}", "select": "*", "order": "created_at.asc"},
        )
    if response.status_code != 200:
        raise SupabaseError(f"email list failed: HTTP {response.status_code}")
    return response.json()


async def list_active_codes() -> list[dict]:
    """Every `interview_codes` row still usable for an interview — the
    scheduler's candidate set. Kept a plain per-row scan (one `find()` call
    per code per reminder type from the caller) rather than a joined query:
    simpler to reason about and to test against the same per-table fakes
    every other store module in this service already uses."""
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.get(
            f"{SUPABASE_URL}/rest/v1/interview_codes",
            headers=_headers(), params={"status": "eq.active", "select": "*"},
        )
    if response.status_code != 200:
        raise SupabaseError(f"interview_codes lookup failed: HTTP {response.status_code}")
    return response.json()


async def create_pending(code_id: str, organization_id: str, email_type: str) -> dict:
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.post(
            f"{SUPABASE_URL}/rest/v1/interview_code_emails",
            headers={**_headers(), "Prefer": "return=representation"},
            json={"code_id": code_id, "organization_id": organization_id, "email_type": email_type},
        )
    if response.status_code not in (200, 201):
        raise SupabaseError(f"email row create failed: HTTP {response.status_code} {response.text[:200]}")
    return response.json()[0]


async def update(row_id: str, fields: dict) -> None:
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.patch(
            f"{SUPABASE_URL}/rest/v1/interview_code_emails",
            headers=_headers(), params={"id": f"eq.{row_id}"}, json=fields,
        )
    if response.status_code not in (200, 204):
        raise SupabaseError(f"email row update failed: HTTP {response.status_code} {response.text[:200]}")
