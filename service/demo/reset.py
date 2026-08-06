"""Ticket 19 — Reset Demo.

```
Reset Demo
  -> Delete Sessions (and their event logs)
  -> Delete Codes (their attempts/used state is part of what a demo run consumes)
  -> Restore Initial State (re-seed fresh codes over the same org/roles/candidates)
```

Candidates, their AI profiles, roles, and the organization itself are never
touched here — only interview *activity*, which is what a rehearsal or a
prior demo run leaves behind. That's what makes this safe to call between
presentations without re-uploading resumes or re-running the pipeline.
"""

from __future__ import annotations

from pipeline import demo_store

from . import seed as demo_seed
from .seed_data import DEMO_ORG_NAME


async def reset_demo_environment() -> dict:
    org = await demo_store.find_organization_by_name(DEMO_ORG_NAME)
    if org is None:
        return {
            "status": "no_demo_environment",
            "message": "No demo environment exists yet — call /demo/seed first.",
        }
    org_id = org["id"]

    deleted_session_ids = await demo_store.delete_sessions_and_events_for_org(org_id)
    await demo_store.delete_codes_for_org(org_id)

    reseeded = await demo_seed.seed_demo_environment()
    return {
        "status": "reset",
        "sessions_deleted": len(deleted_session_ids),
        **reseeded,
    }
