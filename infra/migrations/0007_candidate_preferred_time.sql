-- Mirror of the live migration "candidate_preferred_time", applied via the
-- Supabase MCP. Not authoritative — the live database is.
--
-- intake-webhook has always received `preferredTimeIso` from the Google
-- Form (see infra/google-form-apps-script.gs) but never persisted it — by
-- the time the auto-invite trigger fires (candidate_ai_profile reaching
-- READY_FOR_INTERVIEW, which can be minutes after the resume finishes
-- processing), the request body that carried it is long gone. Without a
-- column to land in, "generate a code valid only for the candidate's chosen
-- slot" had no slot to read.

alter table public.candidates
  add column if not exists preferred_time timestamptz;
