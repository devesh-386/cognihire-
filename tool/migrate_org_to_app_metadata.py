"""One-off: copy `organization_id`/`role` from each auth user's user_metadata
into app_metadata, so tenancy stops depending on a field the user can write.

    SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... \
        python tool/migrate_org_to_app_metadata.py --dry-run
    SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... \
        python tool/migrate_org_to_app_metadata.py --apply

## Why this runs BEFORE migration 0012, not after

0012 repoints `auth_organization_id()` — the function every RLS policy calls —
at the app_metadata claim. Applying it while users still carry the org only in
user_metadata resolves NULL for every caller, which fails closed: no rows, for
everyone, until this script has run. Writing app_metadata first is purely
additive (nothing reads it yet), so the safe order is:

    1. this script --apply
    2. apply infra/migrations/0012_auth_org_from_app_metadata.sql
    3. deploy the service + client that read app_metadata
    4. sign everyone out, so no pre-migration token survives

## What it will not do

It does not delete `organization_id` from user_metadata. Leaving the stale
copy is harmless once nothing reads it, and removing it in the same pass would
make step 1 non-reversible if step 2 has to be rolled back. Clean it up in a
later pass, once the new claim is confirmed working in production.

It also does not invent a value: a user with no `organization_id` in either
place is reported and skipped, never defaulted to some organization.
"""

from __future__ import annotations

import argparse
import os
import sys
import urllib.request
import json

SUPABASE_URL = os.environ.get("SUPABASE_URL", "").rstrip("/")
SERVICE_ROLE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")

_KEYS = ("organization_id", "role")


def _request(method: str, path: str, payload: dict | None = None) -> dict:
    body = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(
        f"{SUPABASE_URL}{path}",
        data=body,
        method=method,
        headers={
            "apikey": SERVICE_ROLE_KEY,
            "Authorization": f"Bearer {SERVICE_ROLE_KEY}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(request) as response:
        return json.loads(response.read() or b"{}")


def list_users() -> list[dict]:
    """GoTrue paginates at 50 by default; ask for more and page until short."""
    users: list[dict] = []
    page = 1
    while True:
        result = _request("GET", f"/auth/v1/admin/users?page={page}&per_page=200")
        batch = result.get("users", [])
        users.extend(batch)
        if len(batch) < 200:
            return users
        page += 1


def main() -> int:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--dry-run", action="store_true", help="report what would change")
    group.add_argument("--apply", action="store_true", help="write app_metadata")
    args = parser.parse_args()

    if not SUPABASE_URL or not SERVICE_ROLE_KEY:
        print("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must both be set", file=sys.stderr)
        return 2

    users = list_users()
    print(f"{len(users)} auth users\n")

    changed = skipped = already = 0
    for user in users:
        email = user.get("email") or user["id"]
        user_meta = user.get("user_metadata") or {}
        app_meta = user.get("app_metadata") or {}

        if app_meta.get("organization_id"):
            print(f"  ok      {email}: app_metadata already carries the org")
            already += 1
            continue

        org = user_meta.get("organization_id")
        if not org:
            print(f"  SKIP    {email}: no organization_id in either metadata — needs a human")
            skipped += 1
            continue

        # Merge rather than replace: app_metadata also holds GoTrue's own
        # `provider`/`providers` keys, and clobbering those breaks sign-in.
        merged = {**app_meta, **{k: user_meta[k] for k in _KEYS if k in user_meta}}
        print(f"  MIGRATE {email}: org={org} role={user_meta.get('role')}")
        if args.apply:
            _request("PUT", f"/auth/v1/admin/users/{user['id']}", {"app_metadata": merged})
        changed += 1

    verb = "migrated" if args.apply else "would migrate"
    print(f"\n{verb} {changed}, already done {already}, skipped {skipped}")
    if skipped:
        print("Resolve the skipped users before applying migration 0012 — they will "
              "resolve to NULL and see no rows.", file=sys.stderr)
    if not args.apply:
        print("Dry run only. Re-run with --apply to write.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
