-- Mirror of the live migration "app_config_gateway_url", applied via the
-- Supabase MCP. Not authoritative — the live database is.
--
-- Why this exists: the gateway URL was originally a database-level GUC set
-- via `alter database postgres set app.settings.ai_gateway_url = '...'`.
-- That statement requires superuser, and Supabase's `postgres` role is not
-- one — so the setting could only be applied by hand through the dashboard,
-- and in practice it silently stayed NULL for weeks, which made the resume
-- trigger a no-op that failed invisibly (by design — see 0002's header).
-- A table can be read and written with the privileges the project actually
-- has, and `select * from app_config` answers "is this configured?" in a way
-- a GUC never did.

create table public.app_config (
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);

alter table public.app_config enable row level security;

-- No policies: backend-only configuration. The service-role key bypasses
-- RLS, and the SECURITY DEFINER trigger reads it as the table owner.
-- Nothing an anon/authenticated client holds can see it.

insert into public.app_config (key, value)
values ('ai_gateway_url', 'https://api.cognihire.online');

-- Same function as 0002, with the lookup changed to check the table first
-- and fall back to the GUC, so an operator who does have superuser can
-- still override without editing this function.
create or replace function public.trigger_resume_processing()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  gateway_url text;
begin
  if new.resume_path is null then
    return new;
  end if;

  insert into public.candidate_ai_profile (organization_id, candidate_id, processing_status)
  values (new.organization_id, new.id, 'UPLOADED')
  on conflict (candidate_id) do update
    set processing_status = 'UPLOADED',
        error = null,
        updated_at = now();

  select value into gateway_url from public.app_config where key = 'ai_gateway_url';
  if gateway_url is null or gateway_url = '' then
    gateway_url := current_setting('app.settings.ai_gateway_url', true);
  end if;
  if gateway_url is null or gateway_url = '' then
    return new;
  end if;

  begin
    perform net.http_post(
      url := gateway_url || '/resumes/process',
      body := jsonb_build_object('candidate_id', new.id),
      headers := jsonb_build_object('Content-Type', 'application/json')
    );
  exception when others then
    null;
  end;

  return new;
end;
$$;

revoke execute on function public.trigger_resume_processing() from anon, authenticated, public;
