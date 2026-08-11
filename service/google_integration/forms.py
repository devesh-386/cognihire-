"""Creates a Google Form for one intake via the Forms API (Part 7/9 of the
intake work). Three fields only — Full Name, Email, Resume — the role and
organization are already known from the intake, so the candidate never
chooses (and can't spoof) either.

Whether `drive.file` scope reliably grants read access to a *respondent's*
uploaded file (not the connecting recruiter's own) is a real corner case
flagged in the plan as unverified until tested against a live form — this
module only creates the form; reading a submitted resume back is Phase B's
next slice, not built here.
"""

from __future__ import annotations

import httpx

_FORMS_API = "https://forms.googleapis.com/v1/forms"
_TIMEOUT = 30


class GoogleFormsError(RuntimeError):
    """The Forms API rejected something — the caller maps this to a 502."""


async def create_intake_form(access_token: str, *, title: str) -> dict:
    """Two calls, because the Forms API only lets `forms.create` set the
    title — every question has to be added in a follow-up batchUpdate. Info
    (title/description) can't be changed in the same batchUpdate that adds
    items either, per the API's own documented restriction, so this is the
    minimum two round trips, not an unnecessary extra one."""
    headers = {"Authorization": f"Bearer {access_token}", "Content-Type": "application/json"}

    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        created = await client.post(_FORMS_API, headers=headers, json={
            "info": {"title": title, "documentTitle": title},
        })
    if created.status_code != 200:
        raise GoogleFormsError(f"form creation failed: HTTP {created.status_code} {created.text[:200]}")
    form = created.json()
    form_id = form["formId"]

    requests = [
        _text_question("Full name", index=0, required=True),
        _text_question("Email", index=1, required=True),
        _file_upload_question("Resume", index=2, required=True),
    ]
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        updated = await client.post(
            f"{_FORMS_API}/{form_id}:batchUpdate", headers=headers, json={"requests": requests},
        )
    if updated.status_code != 200:
        raise GoogleFormsError(
            f"form question setup failed: HTTP {updated.status_code} {updated.text[:200]}"
        )

    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        fetched = await client.get(f"{_FORMS_API}/{form_id}", headers=headers)
    if fetched.status_code != 200:
        raise GoogleFormsError(f"could not read back the created form: HTTP {fetched.status_code}")
    final_form = fetched.json()

    return {
        "form_id": form_id,
        "application_url": final_form.get("responderUri"),
    }


def _text_question(title: str, *, index: int, required: bool) -> dict:
    return {
        "createItem": {
            "item": {
                "title": title,
                "questionItem": {"question": {"required": required, "textQuestion": {}}},
            },
            "location": {"index": index},
        }
    }


def _file_upload_question(title: str, *, index: int, required: bool) -> dict:
    return {
        "createItem": {
            "item": {
                "title": title,
                "questionItem": {
                    "question": {
                        "required": required,
                        "fileUploadQuestion": {"maxFiles": 1, "maxFileSize": "10485760"},
                    },
                },
            },
            "location": {"index": index},
        }
    }
