"""`_sign_state` / `_verify_state` — the Google OAuth account-linking guard.

A signed state is a bearer credential for "attach a Google account to this
organization". It used to be good forever: the nonce was generated, signed,
and never looked at again, and nothing carried an expiry. A state recovered
from browser history, a referrer, or a proxy log could be replayed at any
later time with the attacker's own consent code, wiring their Google account
to someone else's hiring pipeline.

These tests pin both halves of the fix — bounded lifetime, and single use.
"""

from __future__ import annotations

import time

import pytest
from fastapi import HTTPException

import main


@pytest.fixture(autouse=True)
def state_secret(monkeypatch):
    monkeypatch.setenv("GOOGLE_OAUTH_STATE_SECRET", "test-state-secret")
    main._consumed_state_nonces.clear()
    yield
    main._consumed_state_nonces.clear()


def test_a_freshly_signed_state_verifies_to_its_org():
    assert main._verify_state(main._sign_state("org-abc")) == "org-abc"


def test_a_state_can_only_be_used_once():
    """The replay this closes. Second presentation of the same state is
    refused even though the signature is still perfectly valid."""
    state = main._sign_state("org-abc")
    assert main._verify_state(state) == "org-abc"

    with pytest.raises(HTTPException) as exc:
        main._verify_state(state)
    assert exc.value.status_code == 400


def test_an_expired_state_is_refused(monkeypatch):
    state = main._sign_state("org-abc")
    # Past the TTL, without waiting ten real minutes. The real function is
    # captured first: `main.time` IS the `time` module, so a lambda that
    # called time.time() after patching would call itself.
    real_time = time.time
    monkeypatch.setattr(main.time, "time", lambda: real_time() + main._STATE_TTL_SECONDS + 1)

    with pytest.raises(HTTPException) as exc:
        main._verify_state(state)
    assert exc.value.status_code == 400


def test_a_tampered_org_is_refused():
    """The core property: the org id is inside the signed payload, so
    swapping it invalidates the signature rather than redirecting the
    connection to another company."""
    state = main._sign_state("org-abc")
    forged = state.replace("org-abc", "org-victim", 1)

    with pytest.raises(HTTPException):
        main._verify_state(forged)


def test_a_forward_dated_state_cannot_extend_its_own_life():
    """issued_at is signed, so an attacker cannot edit it to buy more time
    — the edit breaks the signature first."""
    state = main._sign_state("org-abc")
    payload, _, _ = state.rpartition(":")
    rest, _, issued_at = payload.rpartition(":")
    forged_payload = f"{rest}:{int(issued_at) + 100_000}"
    forged = f"{forged_payload}:{state.rpartition(':')[2]}"

    with pytest.raises(HTTPException):
        main._verify_state(forged)


@pytest.mark.parametrize("junk", ["", "nope", "a:b", "a:b:c", "::::"])
def test_malformed_states_are_refused_not_crashed(junk):
    with pytest.raises(HTTPException) as exc:
        main._verify_state(junk)
    assert exc.value.status_code == 400


def test_org_ids_containing_a_colon_still_round_trip():
    """Parsed from the right precisely so this holds — a left-split would
    misattribute the fields and check the signature over the wrong bytes."""
    assert main._verify_state(main._sign_state("weird:org:id")) == "weird:org:id"


def test_consumed_nonces_do_not_accumulate_forever(monkeypatch):
    """One entry per connect attempt, swept once it is old enough that the
    TTL check would reject it anyway."""
    main._verify_state(main._sign_state("org-abc"))
    assert len(main._consumed_state_nonces) == 1

    real_monotonic = time.monotonic
    monkeypatch.setattr(main.time, "monotonic", lambda: real_monotonic() + main._STATE_TTL_SECONDS + 1)
    main._verify_state(main._sign_state("org-def"))

    assert len(main._consumed_state_nonces) == 1


def test_no_secret_configured_is_a_503_not_an_open_door():
    """An unset GOOGLE_OAUTH_STATE_SECRET must never make verification
    trivially satisfiable."""
    import os
    os.environ.pop("GOOGLE_OAUTH_STATE_SECRET")
    with pytest.raises(HTTPException) as exc:
        main._verify_state("a:b:c:d")
    assert exc.value.status_code == 503
