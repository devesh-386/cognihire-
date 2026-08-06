"""Session orchestration — the layer between the AI stages and the network.

Nothing in here decides anything about a candidate. It loads what the AI
stages need, calls them in the right order, and persists what happened so a
session survives a request boundary, a browser refresh, or a server restart.

```
interview_session.py   the lifecycle: start / answer / finish / report
interview_codes.py      Phase 3: generate / redeem interview codes
state_machine.py        legal status transitions (pure, no I/O)
events.py                the append-only turn-by-turn log
session_store.py         Supabase access for interview_sessions / interview_events
codes_store.py           Supabase access for interview_codes
```

See `ai/__init__.py` for the AI stages this coordinates.
"""

from . import (
    codes_store,
    events,
    interview_codes,
    interview_session,
    session_store,
    state_machine,
)

__all__ = [
    "state_machine",
    "events",
    "session_store",
    "codes_store",
    "interview_session",
    "interview_codes",
]
