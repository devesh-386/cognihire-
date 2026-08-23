"""Which organization a new account lands in.

`/auth/signup` used to look an organization up by NAME and, if it already
existed, create a confirmed HR account inside it. `/roles/open` publishes
organization names to anyone, unauthenticated — so "become a recruiter at any
company you can name" was two HTTP requests, using nothing but the intended
behaviour of both routes.

Signup now creates a NEW organization, or redeems an invitation, and there is
no third path. These tests exist because none of that is visible from reading
a route that returns 200 either way.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

import main
from pipeline import demo_store
from security import rate_limit


class _FakeAuth:
    def __init__(self):
        self.organizations: dict[str, dict] = {}
        self.users: dict[str, dict] = {}
        self.invites: dict[str, dict] = {}
        self._next = 1

    # --- organizations ---
    def seed_organization(self, name: str) -> dict:
        org = {"id": f"org-{self._next}", "name": name}
        self._next += 1
        self.organizations[org["id"]] = org
        return org

    async def find_organization_by_name(self, name):
        return next((o for o in self.organizations.values() if o["name"] == name), None)

    async def create_organization(self, name):
        return self.seed_organization(name)

    async def fetch_organization(self, organization_id):
        return self.organizations.get(organization_id)

    # --- users ---
    async def find_auth_user_by_email(self, email):
        return self.users.get(email)

    async def create_hr_user(self, email, password, organization_id, *, name=None):
        # Mirrors the real one: authorization attributes go in app_metadata,
        # which the account holder cannot write. See migration 0012.
        user = {
            "id": f"user-{len(self.users) + 1}",
            "email": email,
            "app_metadata": {"organization_id": organization_id, "role": "recruiter"},
            "user_metadata": {"name": name} if name else {},
        }
        self.users[email] = user
        return user

    async def sign_in(self, email, password):
        return {"access_token": f"token-for-{email}", "user": self.users[email]}

    # --- invites ---
    def seed_invite(self, organization_id, email, token_hash, *, hours=72, accepted=False):
        invite = {
            "id": f"invite-{len(self.invites) + 1}",
            "organization_id": organization_id,
            "email": email,
            "token_hash": token_hash,
            "expires_at": (datetime.now(timezone.utc) + timedelta(hours=hours)).isoformat(),
            "accepted_at": datetime.now(timezone.utc).isoformat() if accepted else None,
        }
        self.invites[token_hash] = invite
        return invite

    async def create_invite(self, fields):
        return self.seed_invite(
            fields["organization_id"], fields["email"], fields["token_hash"],
        )

    async def fetch_live_invite(self, token_hash):
        invite = self.invites.get(token_hash)
        return invite if invite and invite["accepted_at"] is None else None

    async def mark_invite_accepted(self, invite_id, accepted_at):
        for invite in self.invites.values():
            if invite["id"] == invite_id and invite["accepted_at"] is None:
                invite["accepted_at"] = accepted_at
                return True
        return False


@pytest.fixture
def fake(monkeypatch):
    store = _FakeAuth()
    for name in (
        "find_organization_by_name", "create_organization", "fetch_organization",
        "find_auth_user_by_email", "create_hr_user", "sign_in",
        "create_invite", "fetch_live_invite", "mark_invite_accepted",
    ):
        monkeypatch.setattr(demo_store, name, getattr(store, name))
    return store


@pytest.fixture
def client(fake, monkeypatch):
    rate_limit._reset_for_tests()

    async def fake_resolve(token):
        return {"app_metadata": {"organization_id": token.removeprefix("test-token-")}}

    monkeypatch.setattr(demo_store, "resolve_user_from_token", fake_resolve)
    return TestClient(main.app)


def _signup(client, **fields):
    body = {"email": "new@example.com", "password": "hunter2", **fields}
    return client.post("/auth/signup", json=body)


# --- creating a new organization ---------------------------------------------


def test_signup_creates_a_brand_new_organization(client, fake):
    resp = _signup(client, organization_name="Fresh Co")
    assert resp.status_code == 200, resp.text
    assert resp.json()["organization_name"] == "Fresh Co"


def test_signup_refuses_an_existing_organization_name(client, fake):
    """The attack: read a name off /roles/open, sign up 'into' that company."""
    fake.seed_organization("Acme Inc")

    resp = _signup(client, organization_name="Acme Inc")

    assert resp.status_code == 409
    assert resp.json()["detail"]["reason"] == "organization_exists"
    # And critically: no account was created anywhere near Acme.
    assert fake.users == {}


def test_signup_without_a_name_or_an_invite_is_refused(client):
    resp = _signup(client)
    assert resp.status_code == 422
    assert resp.json()["detail"]["reason"] == "organization_name_required"


def test_signup_refuses_an_email_that_already_has_an_account(client, fake):
    fake.users["new@example.com"] = {"id": "user-existing"}
    resp = _signup(client, organization_name="Fresh Co")
    assert resp.status_code == 409
    assert resp.json()["detail"]["reason"] == "email_registered"


# --- joining by invitation ---------------------------------------------------


def test_a_valid_invite_joins_the_inviting_organization(client, fake):
    org = fake.seed_organization("Acme Inc")
    fake.seed_invite(org["id"], "new@example.com", main._hash_invite_token("tok-1"))

    resp = _signup(client, invite_token="tok-1")

    assert resp.status_code == 200, resp.text
    assert resp.json()["organization_id"] == org["id"]
    assert fake.users["new@example.com"]["app_metadata"]["organization_id"] == org["id"]


def test_an_invite_cannot_be_redeemed_twice(client, fake):
    org = fake.seed_organization("Acme Inc")
    fake.seed_invite(org["id"], "new@example.com", main._hash_invite_token("tok-1"))

    assert _signup(client, invite_token="tok-1").status_code == 200
    second = _signup(client, email="other@example.com", invite_token="tok-1")

    assert second.status_code == 403
    assert second.json()["detail"]["reason"] == "invalid_invite"


def test_an_invite_is_bound_to_the_address_it_was_issued_to(client, fake):
    """Otherwise a forwarded invitation is a shareable key to the company."""
    org = fake.seed_organization("Acme Inc")
    fake.seed_invite(org["id"], "invited@example.com", main._hash_invite_token("tok-1"))

    resp = _signup(client, email="someone-else@example.com", invite_token="tok-1")

    assert resp.status_code == 403
    assert fake.users == {}


def test_an_expired_invite_is_refused(client, fake):
    org = fake.seed_organization("Acme Inc")
    fake.seed_invite(org["id"], "new@example.com", main._hash_invite_token("tok-1"), hours=-1)

    assert _signup(client, invite_token="tok-1").status_code == 403


def test_an_unknown_invite_token_is_refused(client, fake):
    assert _signup(client, invite_token="not-a-real-token").status_code == 403


def test_the_invite_organization_wins_over_a_supplied_name(client, fake):
    """The request may not name an organization the invitation didn't."""
    inviting = fake.seed_organization("Acme Inc")
    other = fake.seed_organization("Victim Corp")
    fake.seed_invite(inviting["id"], "new@example.com", main._hash_invite_token("tok-1"))

    resp = _signup(client, organization_name="Victim Corp", invite_token="tok-1")

    assert resp.status_code == 200, resp.text
    assert resp.json()["organization_id"] == inviting["id"]
    assert resp.json()["organization_id"] != other["id"]


# --- issuing invitations -----------------------------------------------------


def test_creating_an_invite_requires_auth(client):
    resp = client.post("/organizations/invites", json={"email": "x@example.com"})
    assert resp.status_code == 401


def test_an_invite_is_created_for_the_callers_own_org_only(client, fake):
    org = fake.seed_organization("Acme Inc")

    resp = client.post(
        "/organizations/invites",
        json={"email": "New.Person@Example.com"},
        headers={"Authorization": f"Bearer test-token-{org['id']}"},
    )

    assert resp.status_code == 200, resp.text
    body = resp.json()
    # Returned once, and only as the raw token — what is stored is the hash.
    assert body["invite_token"]
    assert body["email"] == "new.person@example.com"
    stored = fake.invites[main._hash_invite_token(body["invite_token"])]
    assert stored["organization_id"] == org["id"]
    assert "invite_token" not in stored
