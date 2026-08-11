"""Supabase access for the resume pipeline.

Uses the service-role key, which bypasses RLS — correct here, because the
backend acts on behalf of the system rather than a signed-in HR user, and it
must write profiles for candidates who have no auth account at all. That key
lives only in this process's environment and is never sent anywhere.
"""

from __future__ import annotations

import os

import httpx

SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
SUPABASE_SERVICE_ROLE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")

RESUME_BUCKET = os.environ.get("RESUME_BUCKET", "resumes")

_TIMEOUT = 30


class SupabaseError(RuntimeError):
    """Raised for configuration or transport failures the caller must see.

    Distinct from a pipeline stage failing: a stage failure is data to record
    on the profile, whereas being unable to reach the database at all means we
    cannot record anything and must not pretend we did.
    """


def _headers() -> dict[str, str]:
    if not SUPABASE_URL or not SUPABASE_SERVICE_ROLE_KEY:
        raise SupabaseError(
            "SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set for the "
            "resume pipeline to read resumes or write profiles"
        )
    return {
        "apikey": SUPABASE_SERVICE_ROLE_KEY,
        "Authorization": f"Bearer {SUPABASE_SERVICE_ROLE_KEY}",
        "Content-Type": "application/json",
    }


async def fetch_candidate(candidate_id: str) -> dict | None:
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.get(
            f"{SUPABASE_URL}/rest/v1/candidates",
            headers=_headers(),
            params={
                "id": f"eq.{candidate_id}",
                "select": "id,organization_id,name,email,resume_path,role_id,preferred_time",
            },
        )
    if response.status_code != 200:
        raise SupabaseError(f"candidate lookup failed: HTTP {response.status_code}")
    rows = response.json()
    return rows[0] if rows else None


async def fetch_organization(organization_id: str) -> dict | None:
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.get(
            f"{SUPABASE_URL}/rest/v1/organizations",
            headers=_headers(),
            params={"id": f"eq.{organization_id}", "select": "id,name"},
        )
    if response.status_code != 200:
        raise SupabaseError(f"organization lookup failed: HTTP {response.status_code}")
    rows = response.json()
    return rows[0] if rows else None


async def download_resume(resume_path: str) -> bytes:
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.get(
            f"{SUPABASE_URL}/storage/v1/object/{RESUME_BUCKET}/{resume_path}",
            headers={"Authorization": f"Bearer {SUPABASE_SERVICE_ROLE_KEY}"},
        )
    if response.status_code != 200:
        raise SupabaseError(f"resume download failed: HTTP {response.status_code}")
    return response.content


async def upsert_profile(candidate_id: str, organization_id: str, fields: dict) -> None:
    payload = {
        "candidate_id": candidate_id,
        "organization_id": organization_id,
        **fields,
    }
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.post(
            f"{SUPABASE_URL}/rest/v1/candidate_ai_profile",
            headers={**_headers(), "Prefer": "resolution=merge-duplicates"},
            params={"on_conflict": "candidate_id"},
            json=payload,
        )
    if response.status_code not in (200, 201, 204):
        raise SupabaseError(
            f"profile upsert failed: HTTP {response.status_code} {response.text[:200]}"
        )


async def fetch_profile(candidate_id: str) -> dict | None:
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.get(
            f"{SUPABASE_URL}/rest/v1/candidate_ai_profile",
            headers=_headers(),
            params={"candidate_id": f"eq.{candidate_id}", "select": "*"},
        )
    if response.status_code != 200:
        raise SupabaseError(f"profile lookup failed: HTTP {response.status_code}")
    rows = response.json()
    return rows[0] if rows else None
