"""Rate limits on the two routes that verify a credential.

`/auth/login` (an HR password) and `/interview/start` (a candidate's
interview code) were the only two public routes in main.py with no limiter
on them at all, while every other public route — `/extract-claims`,
`/candidates/apply`, `/face/analyze`, `/roles/open` — already had one. That
is an omission, not a design decision, and it is exactly backwards: the two
routes that tell a caller whether a guessed secret is correct are the two
that most need a cap.

These tests pin the caps by asserting the attack fails, not by asserting a
decorator exists — a limiter that got the bucket name right and the
threshold wrong would still pass the latter.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from pipeline import demo_store, supabase_store
from security import rate_limit
from session import interview_codes


@pytest.fixture
def client(monkeypatch):
    import main

    rate_limit._reset_for_tests()

    async def refuse_sign_in(email, password):
        # Every attempt is a wrong password. The limiter must count these —
        # one that only counted successful logins would not be a limiter.
        raise supabase_store.SupabaseError("invalid login credentials")

    async def refuse_code(code, _retries_left=3):
        raise interview_codes.CodeError("not_found", "That code was not recognized.")

    monkeypatch.setattr(demo_store, "sign_in", refuse_sign_in)
    monkeypatch.setattr(interview_codes, "start_with_code", refuse_code)

    yield TestClient(main.app)

    rate_limit._reset_for_tests()


def _login(client, email: str):
    return client.post("/auth/login", json={"email": email, "password": "wrong"})


# --- /auth/login -------------------------------------------------------------


def test_password_spraying_one_account_is_capped_by_email(client):
    """The attack: `/auth/signup` returns 409 `email_registered` for an
    address that exists, so recruiter emails are harvestable. Unlimited
    password guesses against a harvested address is then just a loop."""
    for _ in range(5):
        assert _login(client, "hr@acme.test").status_code == 401

    assert _login(client, "hr@acme.test").status_code == 429


def test_the_email_bucket_is_case_and_whitespace_insensitive(client):
    """Otherwise the cap is free to bypass: the same account reached as
    `HR@Acme.test`, ` hr@acme.test `, and `hr@acme.test` would get three
    independent buckets. GoTrue treats them as one account, so this must
    too."""
    for _ in range(5):
        assert _login(client, "hr@acme.test").status_code == 401

    assert _login(client, "  HR@Acme.TEST  ").status_code == 429


def test_a_different_account_is_not_punished_for_the_first_ones_cap(client):
    """The per-email bucket must not become a way to lock someone else out:
    exhausting one address's attempts leaves every other address alone."""
    for _ in range(5):
        assert _login(client, "hr@acme.test").status_code == 401
    assert _login(client, "hr@acme.test").status_code == 429

    assert _login(client, "someone-else@acme.test").status_code == 401


def test_spraying_many_accounts_from_one_host_is_capped_by_ip(client):
    """The complement: a caller who never repeats an email address slips
    past the per-email bucket entirely, so the per-IP bucket has to catch
    it. 20 distinct addresses stay under the 5-per-email cap by
    construction."""
    for i in range(20):
        assert _login(client, f"user{i}@acme.test").status_code == 401

    assert _login(client, "user20@acme.test").status_code == 429


# --- /interview/start --------------------------------------------------------


def test_interview_code_guessing_is_capped(client):
    """An interview code is the candidate's entire credential, and the
    reply distinguishes "no such code" (404) from "exists but not usable"
    (409) — a live/dead oracle worth guessing against if the guessing is
    free."""
    for i in range(10):
        response = client.post("/interview/start", json={"code": f"GUESS{i:03d}"})
        assert response.status_code == 404

    assert client.post("/interview/start", json={"code": "GUESSXXX"}).status_code == 429


def test_interview_start_and_auth_login_do_not_share_a_bucket(client):
    """Separate buckets, so a candidate mistyping their code cannot consume
    a recruiter's login attempts on the same office IP, or vice versa."""
    for i in range(10):
        assert client.post("/interview/start", json={"code": f"GUESS{i:03d}"}).status_code == 404
    assert client.post("/interview/start", json={"code": "GUESSXXX"}).status_code == 429

    assert _login(client, "hr@acme.test").status_code == 401
