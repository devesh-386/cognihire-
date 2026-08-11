"""Creates a Google Form for one intake via the Forms API (Part 7/9 of the
intake work). Full name, email, resume link, phone, LinkedIn/portfolio,
years of experience, and preferred interview time — the role and
organization are already known from the intake, so the candidate never
chooses (and can't spoof) either.

Resume is a text question asking for a link (Drive/Dropbox/etc.), not a
native file-upload question: verified against a live form that the Forms
API rejects `fileUploadQuestion` in batchUpdate with "Creation of
file_upload question not supported" — Google only allows adding that
question type through the Forms UI, never via the API. Not a scope or
permission issue; a hard platform restriction.
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
        _text_question("Phone number", index=2, required=True),
        _text_question("LinkedIn or portfolio URL", index=3, required=False),
        _text_question("Years of experience", index=4, required=True),
        _text_question("Resume link (Google Drive, Dropbox, or other shareable link)", index=5, required=True),
        _date_question("Preferred interview date & time", index=6, required=False),
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


def _date_question(title: str, *, index: int, required: bool) -> dict:
    return {
        "createItem": {
            "item": {
                "title": title,
                "questionItem": {
                    "question": {
                        "required": required,
                        "dateQuestion": {"includeYear": True, "includeTime": True},
                    },
                },
            },
            "location": {"index": index},
        }
    }
