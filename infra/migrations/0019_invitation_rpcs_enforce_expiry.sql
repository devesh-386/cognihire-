-- Companion to 0018: the two anon-facing RPCs must actually check
-- `expires_at`, or the new column is decorative. Both already implicitly
-- exclude a revoked invitation (they only ever match status = 'pending';
-- 'revoked' is a different status), so no separate revocation check is
-- needed here.

create or replace function public.get_redeemable_invitation(p_code text)
returns table(
  id text, organization_id text, candidate_id text, role_id text,
  code text, status text, created_at timestamptz,
  candidate_name text, candidate_email text
)
language sql
security definer
set search_path = 'public', 'pg_temp'
as $$
  select i.id, i.organization_id, i.candidate_id, i.role_id, i.code, i.status,
         i.created_at, c.name, c.email
  from invitations i join candidates c on c.id = i.candidate_id
  where lower(i.code) = lower(p_code)
    and i.status = 'pending'
    and (i.expires_at is null or i.expires_at > now());
$$;

create or replace function public.accept_invitation(p_code text)
returns table(
  id text, organization_id text, candidate_id text, role_id text,
  code text, status text, created_at timestamptz,
  candidate_name text, candidate_email text
)
language plpgsql
security definer
set search_path = 'public', 'pg_temp'
as $$
begin
  return query
    update invitations i set status = 'accepted'
    from candidates c
    where c.id = i.candidate_id
      and lower(i.code) = lower(p_code)
      and i.status = 'pending'
      and (i.expires_at is null or i.expires_at > now())
    returning i.id, i.organization_id, i.candidate_id, i.role_id, i.code, i.status,
              i.created_at, c.name, c.email;
end;
$$;
