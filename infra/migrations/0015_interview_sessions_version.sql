-- Optimistic concurrency for interview_sessions.
--
-- `interview_session.answer()` reads the session row, computes new
-- `outcomes`/`coverage_state`/`current_topic` from that snapshot entirely in
-- Python, then writes the whole row back with a plain PATCH — no lock, no
-- version check. Two concurrent calls for one session (which the live voice
-- relay in session/live_interview.py produces routinely: a candidate
-- speaking in bursts finalizes several transcripts in quick succession, and
-- each one calls `answer()`) both read the same snapshot, and whichever
-- write lands second silently discards the first's result — a lost topic
-- outcome, a duplicated event append, or `current_topic` left pointing at a
-- question that was already answered.
--
-- `codes_store.claim_code` hit the identical shape earlier (two simultaneous
-- redemptions of one interview code) and was fixed with a compare-and-swap
-- PATCH — a single UPDATE whose WHERE clause includes the expected prior
-- value, evaluated atomically by Postgres. `version` gives `update_session`
-- the same tool: increment expected, PATCH filtered on the value the caller
-- actually read, and a lost race returns 0 rows updated instead of silently
-- overwriting.

alter table interview_sessions
  add column version integer not null default 0;
