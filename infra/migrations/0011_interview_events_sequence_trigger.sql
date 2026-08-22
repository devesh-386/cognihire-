-- Server-assigned event sequence numbers.
--
-- `sequence` used to be chosen by the service: read the count of a session's
-- events, then insert count+1 (session_store.next_sequence). That is a
-- read-then-write with no atomicity, against a column carrying
-- `unique (session_id, sequence)`. Two concurrent writers on one session read
-- the same count and the second insert died on the unique constraint, which
-- the API surfaced as HTTP 503. Live symptom: the candidate portal fires its
-- tab/window/fullscreen signals as concurrent fire-and-forget POSTs to
-- /interview/event, so bursts of them (opening devtools raises blur AND
-- visibilitychange together) lost every event after the first — silently, as
-- the client swallows those failures. Behavior evidence the report is built
-- from just went missing.
--
-- Allocation moves into the database, where it can be serialized. The
-- transaction-scoped advisory lock is keyed on session_id, so concurrent
-- inserts for the SAME session queue up while different sessions never block
-- each other. A row-level `for update` would not work here: it locks existing
-- rows, and the race is over a row that does not exist yet (phantom).
--
-- Callers now omit `sequence` entirely. It is still `not null` — Postgres
-- checks constraints after BEFORE triggers run, so the trigger has already
-- filled it in. An explicitly supplied sequence is left alone, which keeps
-- backfills and the existing rows' numbering untouched.

create or replace function assign_interview_event_sequence() returns trigger as $$
begin
  if new.sequence is null then
    perform pg_advisory_xact_lock(hashtextextended(new.session_id, 0));
    select coalesce(max(sequence), 0) + 1
      into new.sequence
      from interview_events
     where session_id = new.session_id;
  end if;
  return new;
end;
$$ language plpgsql;

alter function assign_interview_event_sequence() set search_path = public;

drop trigger if exists interview_events_assign_sequence on interview_events;

create trigger interview_events_assign_sequence
  before insert on interview_events
  for each row execute function assign_interview_event_sequence();
