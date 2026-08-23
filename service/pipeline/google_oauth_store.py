"""Supabase access for `google_oauth_connections` (Part 8 of the intake
work — per-organization Google OAuth, not one CogniHire-owned account).

Same request-per-call shape as `demo_store.py`. Kept separate from it for
the same reason `demo_store.py` is separate from `supabase_store.py`:
nothing outside Google Forms automation needs this table.
"""

from __future__ import annotations

import httpx

from pipeline.supabase_store import SUPABASE_SERVICE_ROLE_KEY, SUPABASE_URL, SupabaseError
from security import token_crypto

_TIMEOUT = 30

# access_token/refresh_token are encrypted in every row this module writes
# and decrypted in every row it returns — callers (google_integration/oauth.py)
# never see ciphertext and never need to know encryption is happening.
_ENCRYPTED_FIELDS = ("access_token", "refresh_token")


def _encrypt_row(fields: dict) -> dict:
    out = dict(fields)
    for field in _ENCRYPTED_FIELDS:
        if out.get(field):
            out[field] = token_crypto.encrypt(out[field])
    return out


def _decrypt_row(row: dict) -> dict:
    out = dict(row)
    for field in _ENCRYPTED_FIELDS:
        if out.get(field):
            out[field] = token_crypto.decrypt(out[field])
    return out


def _headers() -> dict[str, str]:
    if not SUPABASE_URL or not SUPABASE_SERVICE_ROLE_KEY:
        raise SupabaseError("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set")
    return {
        "apikey": SUPABASE_SERVICE_ROLE_KEY,
        "Authorization": f"Bearer {SUPABASE_SERVICE_ROLE_KEY}",
        "Content-Type": "application/json",
    }


async def get_connection(organization_id: str) -> dict | None:
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.get(
            f"{SUPABASE_URL}/rest/v1/google_oauth_connections",
            headers=_headers(),
            params={"organization_id": f"eq.{organization_id}", "select": "*"},
        )
    if response.status_code != 200:
        raise SupabaseError(f"google_oauth_connections lookup failed: HTTP {response.status_code}")
    rows = response.json()
    return _decrypt_row(rows[0]) if rows else None


async def upsert_connection(fields: dict) -> dict:
    """One connection per org (the table's own UNIQUE constraint) — a
    reconnect replaces the existing row's tokens rather than erroring."""
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.post(
            f"{SUPABASE_URL}/rest/v1/google_oauth_connections",
            headers={**_headers(), "Prefer": "return=representation,resolution=merge-duplicates"},
            params={"on_conflict": "organization_id"},
            json=_encrypt_row(fields),
        )
    if response.status_code not in (200, 201):
        raise SupabaseError(
            f"google_oauth_connections upsert failed: HTTP {response.status_code} {response.text[:200]}"
        )
    return _decrypt_row(response.json()[0])
