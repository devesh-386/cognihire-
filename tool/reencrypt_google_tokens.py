"""One-off: encrypt any plaintext access_token/refresh_token still sitting in
`google_oauth_connections`, once `GOOGLE_TOKEN_ENCRYPTION_KEY` exists.

    SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... GOOGLE_TOKEN_ENCRYPTION_KEY=... \
        python tool/reencrypt_google_tokens.py --dry-run
    SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... GOOGLE_TOKEN_ENCRYPTION_KEY=... \
        python tool/reencrypt_google_tokens.py --apply

Idempotent: a row that already decrypts cleanly with the current key is left
alone (re-encrypting it would just be a no-op write). A row that fails to
decrypt is treated as plaintext and gets encrypted — the only other way a
Fernet decrypt fails is a wrong/rotated key, which this script cannot
distinguish from "never encrypted"; if you are mid key-rotation, do that
with the old key still set, not with this script.

Must run in the SAME deploy that first sets GOOGLE_TOKEN_ENCRYPTION_KEY on
the service — see infra/README.md's Google Forms automation section. Before
that env var exists, every row is plaintext by construction, so this script
has nothing to do (it will just fail the same way the service would).
"""

from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "service"))

from cryptography.fernet import InvalidToken  # noqa: E402

from security import token_crypto  # noqa: E402
import urllib.request  # noqa: E402
import json  # noqa: E402

SUPABASE_URL = os.environ.get("SUPABASE_URL", "").rstrip("/")
SERVICE_ROLE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")


def _request(method: str, path: str, payload: dict | None = None) -> object:
    body = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(
        f"{SUPABASE_URL}{path}",
        data=body,
        method=method,
        headers={
            "apikey": SERVICE_ROLE_KEY,
            "Authorization": f"Bearer {SERVICE_ROLE_KEY}",
            "Content-Type": "application/json",
            "Prefer": "return=minimal",
        },
    )
    with urllib.request.urlopen(request) as response:
        raw = response.read()
        return json.loads(raw) if raw else None


def main() -> int:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--dry-run", action="store_true")
    group.add_argument("--apply", action="store_true")
    args = parser.parse_args()

    if not SUPABASE_URL or not SERVICE_ROLE_KEY:
        print("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must both be set", file=sys.stderr)
        return 2
    if not os.environ.get("GOOGLE_TOKEN_ENCRYPTION_KEY"):
        print("GOOGLE_TOKEN_ENCRYPTION_KEY must be set", file=sys.stderr)
        return 2

    rows = _request("GET", "/rest/v1/google_oauth_connections?select=id,organization_id,access_token,refresh_token")
    print(f"{len(rows)} connection row(s)\n")

    changed = already = 0
    for row in rows:
        needs_encryption = False
        for field in ("access_token", "refresh_token"):
            try:
                token_crypto.decrypt(row[field])
            except InvalidToken:
                needs_encryption = True
            except Exception as exc:  # not Fernet-shaped at all -> plaintext
                needs_encryption = True

        if not needs_encryption:
            print(f"  ok      org={row['organization_id']}: already encrypted")
            already += 1
            continue

        print(f"  ENCRYPT org={row['organization_id']}")
        if args.apply:
            _request(
                "PATCH",
                f"/rest/v1/google_oauth_connections?id=eq.{row['id']}",
                {
                    "access_token": token_crypto.encrypt(row["access_token"]),
                    "refresh_token": token_crypto.encrypt(row["refresh_token"]),
                },
            )
        changed += 1

    verb = "encrypted" if args.apply else "would encrypt"
    print(f"\n{verb} {changed}, already done {already}")
    if not args.apply:
        print("Dry run only. Re-run with --apply to write.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
