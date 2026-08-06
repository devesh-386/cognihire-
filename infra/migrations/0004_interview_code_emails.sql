-- Mirror of the live migration "interview_code_emails", applied via the
-- Supabase MCP. Not authoritative — the live database is. Kept here for
-- documentation (Ticket 21 — email automation).

create table interview_code_emails (
  id text primary key default (gen_random_uuid())::text,
  code_id text not null references interview_codes(id) on delete cascade,
  organization_id text not null references organizations(id),

  -- 'invitation' is sent once, automatically, when the code is generated.
  -- 'reminder_1h'/'reminder_30m' are sent by the scheduler as the interview
  -- window approaches. One row per (code, type) — the unique constraint
  -- below is what makes "don't duplicate a reminder" enforceable at the
  -- database level, not just in application logic.
  email_type text not null
    check (email_type in ('invitation', 'reminder_1h', 'reminder_30m')),

  status text not null default 'pending'
    check (status in ('pending', 'sent', 'failed')),

  attempts integer not null default 0,
  last_error text,
  last_attempt_at timestamptz,
  sent_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (code_id, email_type)
);

create index interview_code_emails_code_idx
  on interview_code_emails (code_id);

alter table interview_code_emails enable row level security;

create policy "org members read own interview code emails"
  on interview_code_emails for select
  using (organization_id = auth_organization_id());

-- The backend writes with the service-role key, which bypasses RLS; this
-- policy exists for the HR app's own reads (Email Status section).

create or replace function touch_interview_code_emails()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger interview_code_emails_touch
  before update on interview_code_emails
  for each row execute function touch_interview_code_emails();
