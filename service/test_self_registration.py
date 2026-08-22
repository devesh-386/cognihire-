"""candidates/self_registration.py had no test coverage at all before this
file — the route that lets a stranger submit an application with nothing but
a role/intake id and a self-reported email.

The bug this pins: applying with an email that matched an EXISTING candidate
overwrote that candidate's resume, extracted text, and AI profile, minted a
brand-new interview code bound to their candidate_id, and returned that code
in the HTTP response — to whoever made the request, not to the address on
file. Someone else's résumé and interview, attributed to a real person, with
that person never having done anything.

The fix has three parts, each pinned below: an application matching an
existing candidate never touches that candidate's data, no interview code is
ever returned in the HTTP response (to anyone, new applicant or existing),
and a resume that is oversized or not actually a PDF is refused before it
reaches storage.
"""

from __future__ import annotations

import asyncio
import base64

import pytest

from candidates import self_registration
from pipeline import demo_store
from session import codes_store


_TINY_PDF = b"%PDF-1.4\n%%EOF"
_TINY_PDF_B64 = base64.b64encode(_TINY_PDF).decode()


def _run(coro):
    return asyncio.run(coro)


class _FakeStore:
    def __init__(self):
        self.roles: dict[str, dict] = {}
        self.intakes: dict[str, dict] = {}
        self.candidates: dict[str, dict] = {}
        self.candidates_by_email: dict[tuple[str, str], str] = {}
        self.uploads: dict[str, bytes] = {}
        self.live_codes: dict[str, dict] = {}
        self.generated_codes: list[dict] = []
        self.sent_invitations: list[dict] = []
        self.resent_invitations: list[dict] = []
        self._next = 1

    # --- seeding ---
    def seed_role(self, organization_id="org-1", title="Backend Engineer", **extra):
        role = {"id": f"role-{self._next}", "organization_id": organization_id,
                "title": title, "required_skills": [], **extra}
        self._next += 1
        self.roles[role["id"]] = role
        return role

    def seed_intake(self, role, status="active"):
        intake = {"id": f"intake-{self._next}", "role_id": role["id"], "status": status}
        self._next += 1
        self.intakes[intake["id"]] = intake
        return intake

    def seed_candidate(self, organization_id, email, *, resume_path="orig/resume.pdf"):
        candidate = {
            "id": f"cand-{self._next}", "organization_id": organization_id,
            "email": email, "name": "Original Name", "resume_path": resume_path,
        }
        self._next += 1
        self.candidates[candidate["id"]] = candidate
        self.candidates_by_email[(organization_id, email)] = candidate["id"]
        return candidate

    def seed_live_code(self, candidate_id, **fields):
        code = {"id": f"code-{self._next}", "candidate_id": candidate_id,
                "status": "active", "code": "ABCD1234", **fields}
        self._next += 1
        self.live_codes[candidate_id] = code
        return code

    # --- demo_store surface ---
    async def fetch_role(self, role_id):
        return self.roles.get(role_id)

    async def fetch_intake(self, intake_id):
        return self.intakes.get(intake_id)

    async def find_candidate_by_email(self, organization_id, email):
        cid = self.candidates_by_email.get((organization_id, email))
        return self.candidates.get(cid) if cid else None

    async def create_candidate(self, fields):
        candidate = {"id": f"cand-{self._next}", **fields}
        self._next += 1
        self.candidates[candidate["id"]] = candidate
        self.candidates_by_email[(fields["organization_id"], fields["email"])] = candidate["id"]
        return candidate

    async def update_candidate(self, candidate_id, fields):
        self.candidates[candidate_id].update(fields)

    async def upload_resume_object(self, path, pdf_bytes):
        self.uploads[path] = pdf_bytes

    # --- codes_store surface ---
    async def find_live_code_for_candidate(self, candidate_id):
        return self.live_codes.get(candidate_id)


@pytest.fixture(autouse=True)
def fake_store(monkeypatch):
    store = _FakeStore()
    monkeypatch.setattr(demo_store, "fetch_role", store.fetch_role)
    monkeypatch.setattr(demo_store, "fetch_intake", store.fetch_intake)
    monkeypatch.setattr(demo_store, "find_candidate_by_email", store.find_candidate_by_email)
    monkeypatch.setattr(demo_store, "create_candidate", store.create_candidate)
    monkeypatch.setattr(demo_store, "update_candidate", store.update_candidate)
    monkeypatch.setattr(demo_store, "upload_resume_object", store.upload_resume_object)
    monkeypatch.setattr(codes_store, "find_live_code_for_candidate", store.find_live_code_for_candidate)

    async def fake_process(candidate_id):
        return {"candidate_id": candidate_id, "status": "READY_FOR_INTERVIEW"}

    async def fake_generate(candidate_id, organization_id, role_title, **kw):
        row = {"id": "new-code-id", "code": "FRESH999", "candidate_id": candidate_id,
               "organization_id": organization_id, "role_title": role_title}
        store.generated_codes.append(row)
        return row

    async def fake_send_invitation(code_row, candidate):
        store.sent_invitations.append((code_row, candidate))
        return {"status": "sent"}

    async def fake_resend_invitation(code_row, candidate):
        store.resent_invitations.append((code_row, candidate))
        return {"status": "sent"}

    monkeypatch.setattr(self_registration.profile_builder, "process_candidate_resume", fake_process)
    monkeypatch.setattr(self_registration.interview_codes, "generate", fake_generate)
    monkeypatch.setattr(self_registration.email_workflow, "send_invitation_for_code", fake_send_invitation)
    monkeypatch.setattr(self_registration.email_workflow, "resend_invitation", fake_resend_invitation)
    return store


# --- the core fix: an existing candidate is never overwritten -----------------


def test_new_candidate_registers_normally(fake_store):
    async def _impl():
        role = fake_store.seed_role()

        result = await self_registration.register_candidate(
            role_id=role["id"], name="Ada", email="ada@example.com",
            resume_base64=_TINY_PDF_B64, preferred_time=None,
        )

        assert result["status"] == "application_received"
        candidate_id = fake_store.candidates_by_email[(role["organization_id"], "ada@example.com")]
        assert fake_store.candidates[candidate_id]["resume_path"]
        assert len(fake_store.generated_codes) == 1
        assert len(fake_store.sent_invitations) == 1
    _run(_impl())


def test_applying_with_an_existing_email_does_not_touch_their_resume(fake_store):
    async def _impl():
        """The attack this closes: know a real candidate's email, apply again,
        watch their record get overwritten and a fresh code minted for it."""
        role = fake_store.seed_role()
        victim = fake_store.seed_candidate(role["organization_id"], "victim@example.com",
                                            resume_path="original/path.pdf")
        fake_store.seed_live_code(victim["id"])

        await self_registration.register_candidate(
            role_id=role["id"], name="Impersonator", email="victim@example.com",
            resume_base64=_TINY_PDF_B64, preferred_time=None,
        )

        # Resume path untouched — nothing was ever uploaded over it.
        assert fake_store.candidates[victim["id"]]["resume_path"] == "original/path.pdf"
        assert fake_store.uploads == {}
        # No new candidate row, no new code.
        assert len(fake_store.candidates) == 1
        assert fake_store.generated_codes == []
    _run(_impl())


def test_applying_with_an_existing_email_resends_the_live_code_instead(fake_store):
    async def _impl():
        role = fake_store.seed_role()
        victim = fake_store.seed_candidate(role["organization_id"], "victim@example.com")
        live_code = fake_store.seed_live_code(victim["id"])

        await self_registration.register_candidate(
            role_id=role["id"], name="Impersonator", email="victim@example.com",
            resume_base64=_TINY_PDF_B64, preferred_time=None,
        )

        assert len(fake_store.resent_invitations) == 1
        sent_code, sent_candidate = fake_store.resent_invitations[0]
        assert sent_code["id"] == live_code["id"]
        assert sent_candidate["id"] == victim["id"]
    _run(_impl())


def test_existing_and_new_candidate_responses_are_indistinguishable(fake_store):
    async def _impl():
        """Otherwise the response itself is an oracle for which emails are
        already candidates."""
        role = fake_store.seed_role()
        fake_store.seed_candidate(role["organization_id"], "existing@example.com")

        new_result = await self_registration.register_candidate(
            role_id=role["id"], name="A", email="brand-new@example.com",
            resume_base64=_TINY_PDF_B64, preferred_time=None,
        )
        existing_result = await self_registration.register_candidate(
            role_id=role["id"], name="B", email="existing@example.com",
            resume_base64=_TINY_PDF_B64, preferred_time=None,
        )

        assert new_result.keys() == existing_result.keys()
        assert new_result["status"] == existing_result["status"] == "application_received"
    _run(_impl())


def test_an_existing_candidate_with_no_live_code_yet_is_a_silent_no_op(fake_store):
    async def _impl():
        """Their first application is still processing — there is nothing safe
        to resend, and this path must never create a fresh one; that would just
        be the overwrite bug wearing a different code path."""
        role = fake_store.seed_role()
        fake_store.seed_candidate(role["organization_id"], "pending@example.com")

        result = await self_registration.register_candidate(
            role_id=role["id"], name="Impersonator", email="pending@example.com",
            resume_base64=_TINY_PDF_B64, preferred_time=None,
        )

        assert result["status"] == "application_received"
        assert fake_store.generated_codes == []
        assert fake_store.resent_invitations == []
    _run(_impl())


# --- the interview code is never in the HTTP-facing response ------------------


def test_the_response_never_contains_an_interview_code(fake_store):
    async def _impl():
        role = fake_store.seed_role()
        result = await self_registration.register_candidate(
            role_id=role["id"], name="Ada", email="ada@example.com",
            resume_base64=_TINY_PDF_B64, preferred_time=None,
        )
        assert "code" not in result
    _run(_impl())


# --- resume validation ---------------------------------------------------------


def test_an_oversized_resume_is_refused(fake_store):
    async def _impl():
        role = fake_store.seed_role()
        huge = base64.b64encode(b"%PDF-1.4" + b"0" * (self_registration._MAX_RESUME_BYTES)).decode()

        with pytest.raises(self_registration.SelfRegistrationError, match="15MB"):
            await self_registration.register_candidate(
                role_id=role["id"], name="Ada", email="ada@example.com",
                resume_base64=huge, preferred_time=None,
            )
        assert fake_store.uploads == {}
    _run(_impl())


def test_a_non_pdf_upload_is_refused(fake_store):
    async def _impl():
        role = fake_store.seed_role()
        not_a_pdf = base64.b64encode(b"MZ\x90\x00this is not a pdf").decode()

        with pytest.raises(self_registration.SelfRegistrationError, match="PDF"):
            await self_registration.register_candidate(
                role_id=role["id"], name="Ada", email="ada@example.com",
                resume_base64=not_a_pdf, preferred_time=None,
            )
        assert fake_store.uploads == {}
    _run(_impl())


def test_invalid_base64_is_refused(fake_store):
    async def _impl():
        role = fake_store.seed_role()
        with pytest.raises(self_registration.SelfRegistrationError, match="base64"):
            await self_registration.register_candidate(
                role_id=role["id"], name="Ada", email="ada@example.com",
                resume_base64="not valid base64 !!!", preferred_time=None,
            )
    _run(_impl())


# --- intake-keyed path ----------------------------------------------------------


def test_intake_path_resolves_role_and_still_hides_the_code(fake_store):
    async def _impl():
        role = fake_store.seed_role()
        intake = fake_store.seed_intake(role)

        result = await self_registration.register_candidate(
            intake_id=intake["id"], name="Ada", email="ada@example.com",
            resume_base64=_TINY_PDF_B64, preferred_time=None,
        )

        assert result["intake_id"] == intake["id"]
        assert "code" not in result
    _run(_impl())


def test_a_closed_intake_is_refused(fake_store):
    async def _impl():
        role = fake_store.seed_role()
        intake = fake_store.seed_intake(role, status="closed")

        with pytest.raises(self_registration.SelfRegistrationError):
            await self_registration.register_candidate(
                intake_id=intake["id"], name="Ada", email="ada@example.com",
                resume_base64=_TINY_PDF_B64, preferred_time=None,
            )
    _run(_impl())
