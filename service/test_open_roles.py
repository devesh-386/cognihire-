"""Which application form a public open-roles listing points a candidate at.

`/apply` used to send every candidate to the portal's own résumé upload,
which quietly opened a second intake path alongside the Google Form that the
Apps Script trigger and the intake poller already feed. A role whose intake
has a generated form now links to that form instead, so applicants for the
same role all enter through one pipeline.

The selection rule is the part worth pinning: *active* intake, form actually
generated, and a role with neither still listed rather than dropped.
"""

from __future__ import annotations

from main import intake_application_url

FORM = "https://docs.google.com/forms/d/e/1FAIpQLS-example/viewform"


def test_an_active_intake_with_a_form_supplies_the_url():
    role = {"intakes": [{"status": "active", "application_url": FORM}]}
    assert intake_application_url(role) == FORM


def test_a_closed_intakes_form_is_never_offered():
    """Google keeps accepting responses on a closed campaign's form, and
    intake-webhook would attribute them to that closed intake by formId."""
    role = {"intakes": [{"status": "closed", "application_url": FORM}]}
    assert intake_application_url(role) is None


def test_a_draft_intake_is_not_offered_either():
    role = {"intakes": [{"status": "draft", "application_url": FORM}]}
    assert intake_application_url(role) is None


def test_an_active_intake_whose_form_was_never_generated_yields_none():
    role = {"intakes": [{"status": "active", "application_url": None}]}
    assert intake_application_url(role) is None


def test_the_active_intake_wins_over_a_closed_one_on_the_same_role():
    """A role re-run across two campaigns carries both intakes; embedding is
    unordered, so the rule has to be status-driven, not position-driven."""
    role = {
        "intakes": [
            {"status": "closed", "application_url": "https://forms.example/old"},
            {"status": "active", "application_url": FORM},
        ]
    }
    assert intake_application_url(role) == FORM


def test_a_role_with_no_intakes_at_all_yields_none():
    """Falls back to the portal's own apply page rather than disappearing
    from the list — every role stays browsable."""
    assert intake_application_url({"intakes": []}) is None


def test_a_missing_intakes_key_is_tolerated():
    """PostgREST omits an embedded array entirely in some shapes; a public
    route must not 500 on that."""
    assert intake_application_url({}) is None
    assert intake_application_url({"intakes": None}) is None
