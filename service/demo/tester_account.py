"""A single hardcoded HR tester account for local/staging manual testing of
the company portal, so a developer isn't forced through `/auth/signup` every
time they need a session.

This is NOT a login bypass: the account is a real row in Supabase's `auth`
schema, created through the exact same `demo_store.create_hr_user` call
`/demo/seed`'s HR login already uses, and it signs in through the normal
`/auth/login` password grant — nothing in the auth code path knows or cares
that this particular user is "the tester." The only special thing about it is
that `seed_tester_account()` exists to create it on demand instead of making
a developer click through the signup form.

Kept out of production by the caller (`main.py`'s `/dev/seed-tester-account`
route), which refuses to run unless `ENVIRONMENT` is unset or not
"production" — see that route for the guard itself. This module makes no
environment check of its own; it is not meant to be called from anywhere else.
"""

from __future__ import annotations

from pipeline import demo_store

TESTER_ORG_NAME = "CogniHire Test Company"
TESTER_NAME = "Devesh Tester"
TESTER_EMAIL = "tester@cognihire.local"
TESTER_PASSWORD = "CogniHireTest@2026!"


async def seed_tester_account() -> dict:
    """Idempotent, same as `demo/seed.py`: re-running finds the existing
    org/user by name/email rather than duplicating them."""
    org = await demo_store.find_organization_by_name(TESTER_ORG_NAME)
    if org is None:
        org = await demo_store.create_organization(TESTER_ORG_NAME)

    user = await demo_store.find_or_create_hr_user(
        TESTER_EMAIL, TESTER_PASSWORD, org["id"], name=TESTER_NAME,
    )

    return {
        "organization_id": org["id"],
        "organization_name": org["name"],
        "user_id": user.get("id"),
        "email": TESTER_EMAIL,
        # Password is deliberately echoed back here — this route only runs
        # outside production, and the whole point is a developer who doesn't
        # already know it can read it from the response once.
        "password": TESTER_PASSWORD,
    }
