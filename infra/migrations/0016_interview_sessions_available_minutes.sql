-- Enforceable interview time limit (§6.3).
--
-- `available_minutes` was only ever an HR-configured input to question
-- planning (ai/question_planning.py) — it shaped how many topics/questions
-- a plan asked for, but nothing on the session itself remembered it after
-- the plan was built, and nothing ever checked the wall clock against it.
-- A candidate (or a live-relay WebSocket left open) could keep answering
-- indefinitely; each answer is a paid model call.
--
-- Stored on the session (not just read off the code at start time) because
-- `interview_session.answer()`/`interview_codes.start_with_code`'s resume
-- path both need it and neither has the originating code row to hand —
-- `interview_sessions` already has `started_at`, so the deadline is simply
-- `started_at + available_minutes` from here on.

alter table interview_sessions
  add column available_minutes integer not null default 20;
