-- Truncation disclosure (§4.5).
--
-- claim_extraction.py caps how many claims it keeps (_MAX_CANDIDATES = 8) —
-- a candidate with more usable claims than that gets an interview built
-- from a subset, with nothing recording that it happened. pipeline/
-- profile_builder.py now persists whether that cap was actually hit, so
-- session/interview_session.start can thread it into the question plan and
-- the interview report can disclose it (ai/report_generation.py's
-- TransparencyMetrics.claims_truncated) instead of silently reading as
-- complete coverage of everything the candidate claimed.

alter table candidate_ai_profile
  add column claims_truncated boolean not null default false;
