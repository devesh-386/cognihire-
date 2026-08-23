"""Symmetric encryption for third-party OAuth tokens stored at rest.

`google_oauth_connections.access_token`/`refresh_token` were stored as
plaintext — anyone with read access to the database (a leaked service-role
key, a misconfigured RLS policy, a database backup) could use them directly
against Google's API. This is the only module that touches the key; every
other caller goes through `encrypt`/`decrypt`.

Fernet (AES-128-CBC + HMAC, from the `cryptography` package) rather than
anything hand-rolled: it is authenticated (tampering is detected, not just
unreadable) and versioned (a `GOOGLE_TOKEN_ENCRYPTION_KEY` rotation can be
supported later by trying each key in turn — not built yet because there is
only ever one key today, but the format doesn't foreclose it).

The key itself must live outside the database it protects — an env var, not
a table — otherwise a database compromise defeats the encryption along with
everything else.
"""

from __future__ import annotations

import os

from cryptography.fernet import Fernet, InvalidToken


class TokenCryptoError(RuntimeError):
    """GOOGLE_TOKEN_ENCRYPTION_KEY is missing, malformed, or doesn't match
    what a stored value was encrypted with."""


def _fernet() -> Fernet:
    key = os.environ.get("GOOGLE_TOKEN_ENCRYPTION_KEY")
    if not key:
        raise TokenCryptoError(
            "GOOGLE_TOKEN_ENCRYPTION_KEY is not set — required to store or read Google "
            "OAuth tokens. Generate one with: python -c \"from cryptography.fernet import "
            "Fernet; print(Fernet.generate_key().decode())\" and set it as a secret on the "
            "deployment, never committed to the repo."
        )
    try:
        return Fernet(key.encode())
    except (ValueError, TypeError) as exc:
        raise TokenCryptoError("GOOGLE_TOKEN_ENCRYPTION_KEY is not a valid Fernet key") from exc


def encrypt(plaintext: str) -> str:
    return _fernet().encrypt(plaintext.encode()).decode()


def decrypt(ciphertext: str) -> str:
    try:
        return _fernet().decrypt(ciphertext.encode()).decode()
    except InvalidToken as exc:
        raise TokenCryptoError(
            "stored value could not be decrypted with the current "
            "GOOGLE_TOKEN_ENCRYPTION_KEY — wrong key, or the value predates encryption"
        ) from exc
