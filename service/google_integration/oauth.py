"""Per-organization Google OAuth (Part 8 of the intake work).

Requires a Google Cloud OAuth 2.0 Client ID (Web application type) with the
Forms + Drive.file APIs enabled — see infra/README.md's "Google Forms
automation" section for exactly what to create and where GOOGLE_OAUTH_*
env vars go. Until those are set, `_client_config()` raises rather than
silently no-opping — every route in main.py that reaches this module maps
that to a clear 503, not a confusing generic failure.

Scopes are deliberately narrow: `forms.body` (create/edit forms) and
`drive.file` (read only files this app itself touches) — never full Drive
access.
"""

from __future__ import annotations

import os
import time

import httpx

from pipeline import google_oauth_store
from pipeline.supabase_store import SupabaseError

_AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth"
_TOKEN_URL = "https://oauth2.googleapis.com/token"
_SCOPES = "https://www.googleapis.com/auth/forms.body https://www.googleapis.com/auth/drive.file"
_TIMEOUT = 30


class GoogleOAuthError(RuntimeError):
    """Google's own token/userinfo endpoint rejected something — the caller
    maps this to a 502/503, distinct from our own config being missing."""


def _client_config() -> tuple[str, str, str]:
    client_id = os.environ.get("GOOGLE_OAUTH_CLIENT_ID")
    client_secret = os.environ.get("GOOGLE_OAUTH_CLIENT_SECRET")
    redirect_uri = os.environ.get("GOOGLE_OAUTH_REDIRECT_URI")
    if not client_id or not client_secret or not redirect_uri:
        raise SupabaseError(
            "Google OAuth is not configured — GOOGLE_OAUTH_CLIENT_ID/"
            "GOOGLE_OAUTH_CLIENT_SECRET/GOOGLE_OAUTH_REDIRECT_URI must be set. "
            "See infra/README.md's Google Forms automation section."
        )
    return client_id, client_secret, redirect_uri


def build_authorize_url(state: str) -> str:
    """`state` is a signed {organization_id, nonce} the caller minted — see
    main.py's /organizations/{id}/google/connect — verified on the way back
    in exchange_code_for_tokens's caller so a forged callback can't attach
    someone else's Google account to your organization."""
    client_id, _secret, redirect_uri = _client_config()
    params = {
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": _SCOPES,
        "access_type": "offline",  # required to get a refresh_token back
        "prompt": "consent",  # otherwise a returning user never gets a fresh refresh_token
        "state": state,
    }
    return f"{_AUTHORIZE_URL}?{httpx.QueryParams(params)}"


async def exchange_code_for_tokens(code: str) -> dict:
    client_id, client_secret, redirect_uri = _client_config()
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.post(_TOKEN_URL, data={
            "code": code,
            "client_id": client_id,
            "client_secret": client_secret,
            "redirect_uri": redirect_uri,
            "grant_type": "authorization_code",
        })
    if response.status_code != 200:
        raise GoogleOAuthError(f"token exchange failed: HTTP {response.status_code} {response.text[:200]}")
    return response.json()


async def _refresh(refresh_token: str) -> dict:
    client_id, client_secret, _redirect_uri = _client_config()
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        response = await client.post(_TOKEN_URL, data={
            "refresh_token": refresh_token,
            "client_id": client_id,
            "client_secret": client_secret,
            "grant_type": "refresh_token",
        })
    if response.status_code != 200:
        raise GoogleOAuthError(f"token refresh failed: HTTP {response.status_code} {response.text[:200]}")
    return response.json()


async def get_valid_access_token(organization_id: str) -> str:
    """The one thing Forms-automation code should ever call: returns a live
    access token for the org's connected Google account, transparently
    refreshing if the stored one has expired. Raises SupabaseError if the
    org has no connection at all — the caller (POST /intakes/{id}/
    google-form) maps that to "connect Google first", not a 500."""
    connection = await google_oauth_store.get_connection(organization_id)
    if connection is None:
        raise SupabaseError(f"organization {organization_id} has no Google connection")

    expires_at = connection["token_expires_at"]
    # 60s of slack so a token that's about to expire mid-request still works.
    if _seconds_until(expires_at) > 60:
        return connection["access_token"]

    refreshed = await _refresh(connection["refresh_token"])
    new_expiry = time.time() + refreshed["expires_in"]
    await google_oauth_store.upsert_connection({
        "organization_id": organization_id,
        "google_account_email": connection["google_account_email"],
        "access_token": refreshed["access_token"],
        "refresh_token": connection.get("refresh_token"),  # Google omits it on refresh; keep the original
        "token_expires_at": _iso(new_expiry),
        "scope": connection["scope"],
    })
    return refreshed["access_token"]


def _seconds_until(iso_timestamp: str) -> float:
    import datetime
    target = datetime.datetime.fromisoformat(iso_timestamp)
    return (target - datetime.datetime.now(datetime.timezone.utc)).total_seconds()


def _iso(epoch_seconds: float) -> str:
    import datetime
    return datetime.datetime.fromtimestamp(epoch_seconds, tz=datetime.timezone.utc).isoformat()
