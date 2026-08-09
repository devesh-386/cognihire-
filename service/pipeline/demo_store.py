"""Supabase access for Ticket 19's demo environment — organizations, roles,
candidates, HR login, and cleanup of interview activity on reset.

Same request-per-call shape as `session/codes_store.py`. Kept separate from
`supabase_store.py` because nothing outside the demo feature needs to create
organizations, roles, or an HR auth user.
"""

from __future__ import annotations

import httpx

from pipeline.supabase_store import RESUME_BUCKET, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_URL, SupabaseError

_TIMEOUT = 30


def _headers() -> dict[str, str]:
    if not SUPABASE_URL or not SUPABASE_SERVICE_ROLE_KEY:
        raise SupabaseError(
            "SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set for the demo environment"
        )
    return {
        "apikey": SUPABASE_SERVICE_ROLE_KEY,
        "Authorization": f"Bearer {SUPABASE_SERVICE_ROLE_KEY}",
        "Content-Type": "application/json",
    }


async def _get_one(table: str, params: dict) -> dict | None:
    rows = await _get_many(table, params)
    return rows[0] if rows else None


async def _get_many(table: str, params: dict) -> list[dict]:
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.get(f"{SUPABASE_URL}/rest/v1/{table}", headers=_headers(), params=params)
    if response.status_code != 200:
        raise SupabaseError(f"{table} lookup failed: HTTP {response.status_code}")
    return response.json()


async def _insert_one(table: str, fields: dict) -> dict:
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.post(
            f"{SUPABASE_URL}/rest/v1/{table}",
            headers={**_headers(), "Prefer": "return=representation"},
            json=fields,
        )
    if response.status_code not in (200, 201):
        raise SupabaseError(f"{table} insert failed: HTTP {response.status_code} {response.text[:200]}")
    return response.json()[0]


async def _update(table: str, row_id: str, fields: dict) -> None:
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.patch(
            f"{SUPABASE_URL}/rest/v1/{table}",
            headers=_headers(), params={"id": f"eq.{row_id}"}, json=fields,
        )
    if response.status_code not in (200, 204):
        raise SupabaseError(f"{table} update failed: HTTP {response.status_code} {response.text[:200]}")


async def _delete(table: str, params: dict) -> None:
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.request(
            "DELETE", f"{SUPABASE_URL}/rest/v1/{table}", headers=_headers(), params=params,
        )
    if response.status_code not in (200, 204):
        raise SupabaseError(f"{table} delete failed: HTTP {response.status_code} {response.text[:200]}")


async def find_organization_by_name(name: str) -> dict | None:
    return await _get_one("organizations", {"name": f"eq.{name}", "select": "*"})


async def fetch_organization(organization_id: str) -> dict | None:
    return await _get_one("organizations", {"id": f"eq.{organization_id}", "select": "*"})


async def create_organization(name: str) -> dict:
    return await _insert_one("organizations", {"name": name})


async def find_role(organization_id: str, title: str) -> dict | None:
    return await _get_one("roles", {
        "organization_id": f"eq.{organization_id}", "title": f"eq.{title}", "select": "*",
    })


async def create_role(fields: dict) -> dict:
    return await _insert_one("roles", fields)


async def fetch_role(role_id: str) -> dict | None:
    return await _get_one("roles", {"id": f"eq.{role_id}", "select": "*"})


async def find_candidate_by_email(organization_id: str, email: str) -> dict | None:
    return await _get_one("candidates", {
        "organization_id": f"eq.{organization_id}", "email": f"eq.{email}", "select": "*",
    })


async def create_candidate(fields: dict) -> dict:
    return await _insert_one("candidates", fields)


async def update_candidate(candidate_id: str, fields: dict) -> None:
    await _update("candidates", candidate_id, fields)


async def upload_resume_object(path: str, pdf_bytes: bytes) -> None:
    """`x-upsert` makes re-seeding idempotent — a re-run overwrites the same
    synthetic resume rather than erroring on an existing object."""
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.post(
            f"{SUPABASE_URL}/storage/v1/object/{RESUME_BUCKET}/{path}",
            headers={
                "Authorization": f"Bearer {SUPABASE_SERVICE_ROLE_KEY}",
                "Content-Type": "application/pdf",
                "x-upsert": "true",
            },
            content=pdf_bytes,
        )
    if response.status_code not in (200, 201):
        raise SupabaseError(f"resume upload failed: HTTP {response.status_code} {response.text[:200]}")


async def find_auth_user_by_email(email: str) -> dict | None:
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.get(
            f"{SUPABASE_URL}/auth/v1/admin/users",
            headers=_headers(), params={"per_page": 200},
        )
    if response.status_code != 200:
        raise SupabaseError(f"auth user lookup failed: HTTP {response.status_code}")
    for user in response.json().get("users", []):
        if user.get("email") == email:
            return user
    return None


async def create_hr_user(
    email: str, password: str, organization_id: str, *, name: str | None = None,
) -> dict:
    user_metadata = {"organization_id": organization_id}
    if name:
        user_metadata["name"] = name
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.post(
            f"{SUPABASE_URL}/auth/v1/admin/users",
            headers=_headers(),
            json={
                "email": email,
                "password": password,
                "email_confirm": True,
                "user_metadata": user_metadata,
            },
        )
    if response.status_code not in (200, 201):
        raise SupabaseError(f"HR user create failed: HTTP {response.status_code} {response.text[:200]}")
    return response.json()


async def find_or_create_hr_user(
    email: str, password: str, organization_id: str, *, name: str | None = None,
) -> dict:
    existing = await find_auth_user_by_email(email)
    if existing is not None:
        return existing
    return await create_hr_user(email, password, organization_id, name=name)


async def delete_sessions_and_events_for_org(organization_id: str) -> list[str]:
    """Sessions and their event logs only — candidates, profiles, roles, and
    the org itself are left untouched, per Ticket 19's 'preserve seeded
    data' requirement."""
    sessions = await _get_many("interview_sessions", {
        "organization_id": f"eq.{organization_id}", "select": "id",
    })
    session_ids = [s["id"] for s in sessions]
    if session_ids:
        ids_filter = "(" + ",".join(session_ids) + ")"
        await _delete("interview_events", {"session_id": f"in.{ids_filter}"})
        await _delete("interview_sessions", {"organization_id": f"eq.{organization_id}"})
    return session_ids


async def delete_codes_for_org(organization_id: str) -> None:
    await _delete("interview_codes", {"organization_id": f"eq.{organization_id}"})


# ---------------------------------------------------------------------------
# HR auth (portal login/signup) and org-scoped listing.
#
# GoTrue's password grant and /auth/v1/user both accept the service-role key
# as `apikey` (it's a valid project JWT) — no separate anon key needed, so
# this reuses the same SUPABASE_SERVICE_ROLE_KEY every other module here does.
# ---------------------------------------------------------------------------


async def sign_in(email: str, password: str) -> dict:
    """Password-grant sign-in. Raises SupabaseError with the GoTrue error
    message on bad credentials — the caller maps that to a 401."""
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.post(
            f"{SUPABASE_URL}/auth/v1/token",
            headers=_headers(),
            params={"grant_type": "password"},
            json={"email": email, "password": password},
        )
    if response.status_code != 200:
        detail = response.json().get("error_description") or response.text[:200]
        raise SupabaseError(detail)
    return response.json()


async def resolve_user_from_token(access_token: str) -> dict:
    """Resolves a portal bearer token back to its GoTrue user, so a list
    endpoint can scope its query to `user_metadata.organization_id` without
    trusting an org id the client could otherwise just send itself."""
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.get(
            f"{SUPABASE_URL}/auth/v1/user",
            headers={**_headers(), "Authorization": f"Bearer {access_token}"},
        )
    if response.status_code != 200:
        raise SupabaseError("invalid or expired session")
    return response.json()


async def list_roles(organization_id: str) -> list[dict]:
    return await _get_many("roles", {
        "organization_id": f"eq.{organization_id}", "select": "*", "order": "created_at.desc",
    })


async def list_open_roles() -> list[dict]:
    """Public: every role across every organization, with just enough to
    render a "browse open roles" list and link into `/apply/{role_id}`.
    There is no closed/open status column yet — every role that exists is
    open — so this is the full table, org name embedded via PostgREST's
    resource embedding rather than a second round trip per role."""
    return await _get_many("roles", {
        "select": "id,title,created_at,organizations(name)",
        "order": "created_at.desc",
    })


async def list_candidates(organization_id: str) -> list[dict]:
    """Powers the portal's Candidates list. `processing_status` is attached
    from `candidate_ai_profile` (a separate table — a candidate row exists
    before its resume has been processed, so there's no FK to embed) rather
    than left for the frontend to guess at from `resume_path` alone; `None`
    means no profile exists yet at all (resume just uploaded, trigger hasn't
    fired), distinct from an explicit "FAILED" or "READY_FOR_INTERVIEW"."""
    candidates = await _get_many("candidates", {
        "organization_id": f"eq.{organization_id}", "select": "*", "order": "created_at.desc",
    })
    profiles = await _get_many("candidate_ai_profile", {
        "organization_id": f"eq.{organization_id}", "select": "candidate_id,processing_status",
    })
    status_by_candidate = {p["candidate_id"]: p["processing_status"] for p in profiles}
    for candidate in candidates:
        candidate["processing_status"] = status_by_candidate.get(candidate["id"])
    return candidates
