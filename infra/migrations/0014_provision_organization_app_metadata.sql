-- `provision_organization()` is the Flutter recruiter app's RPC for turning
-- a freshly-registered account into one that owns an organization (called
-- from lib/main.dart's `_provisionOrganization`, right after sign-up). It
-- existed only as a live migration ("role_delete_policy_and_org_provisioning"
-- via the Supabase MCP) with no file in this repo at all — discovered while
-- baselining the schema for infra/migrations/0000_baseline.sql, not from
-- reading any FastAPI code, since it is called directly from the Flutter
-- client and never touches the Python backend.
--
-- It stamped `organization_id` into `raw_user_meta_data`, the account's OWN
-- metadata — the exact field migration 0012 moved every RLS policy and the
-- backend's `_require_org` off of, because GoTrue lets the account holder
-- rewrite it with their own token. Left as-is, this function would have kept
-- writing to a field that, after 0012, grants nothing: a Flutter user who
-- registers via this path would have an organization row created, a
-- confirmed account, and zero working access to anything in it — RLS
-- resolves `auth_organization_id()` to NULL for them, and Flutter's own
-- `principalFromUser` (post-0012) reads `appMetadata`, which this function
-- never touched. Not a hole; a self-inflicted lockout, and one this repo's
-- own tests could not have caught since nothing in the Python test suite
-- exercises a Supabase RPC.
--
-- `app_metadata` is not directly writable via the client SDK the way
-- `user_metadata` is, even from a SECURITY DEFINER function running as the
-- function owner rather than the caller — same privilege level the
-- migration-0011/0012/0013 backfill already used to write `raw_app_meta_data`
-- directly. `auth.uid() is null` still gates who may call this at all; that
-- part of the function is unchanged.

create or replace function public.provision_organization(org_name text) returns text
  language plpgsql
  security definer
  set search_path to 'public', 'pg_temp'
as $function$
declare
  new_org_id text;
begin
  if auth.uid() is null then
    raise exception 'must be signed in';
  end if;

  insert into organizations (name) values (org_name) returning id into new_org_id;

  update auth.users
    set raw_app_meta_data = raw_app_meta_data
      || jsonb_build_object('organization_id', new_org_id, 'role', 'recruiter')
    where id = auth.uid();

  return new_org_id;
end;
$function$;
