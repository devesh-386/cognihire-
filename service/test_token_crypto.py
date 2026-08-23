from __future__ import annotations

import pytest
from cryptography.fernet import Fernet

from security import token_crypto


@pytest.fixture(autouse=True)
def key(monkeypatch):
    monkeypatch.setenv("GOOGLE_TOKEN_ENCRYPTION_KEY", Fernet.generate_key().decode())


def test_round_trips():
    ciphertext = token_crypto.encrypt("ya29.a0-real-looking-token")
    assert ciphertext != "ya29.a0-real-looking-token"
    assert token_crypto.decrypt(ciphertext) == "ya29.a0-real-looking-token"


def test_missing_key_raises_clear_error(monkeypatch):
    monkeypatch.delenv("GOOGLE_TOKEN_ENCRYPTION_KEY", raising=False)
    with pytest.raises(token_crypto.TokenCryptoError, match="not set"):
        token_crypto.encrypt("x")


def test_malformed_key_raises_clear_error(monkeypatch):
    monkeypatch.setenv("GOOGLE_TOKEN_ENCRYPTION_KEY", "not-a-real-fernet-key")
    with pytest.raises(token_crypto.TokenCryptoError, match="not a valid Fernet key"):
        token_crypto.encrypt("x")


def test_decrypting_plaintext_raises_instead_of_returning_garbage():
    with pytest.raises(token_crypto.TokenCryptoError):
        token_crypto.decrypt("this-was-never-encrypted")


def test_wrong_key_cannot_decrypt(monkeypatch):
    ciphertext = token_crypto.encrypt("secret")
    monkeypatch.setenv("GOOGLE_TOKEN_ENCRYPTION_KEY", Fernet.generate_key().decode())
    with pytest.raises(token_crypto.TokenCryptoError):
        token_crypto.decrypt(ciphertext)
