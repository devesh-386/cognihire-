# Ticket 8 — Supabase project + minimal schema

Project: `cognihire` (`foffzvwmxnsmbixkilxt`, ap-south-1), free tier, ACTIVE_HEALTHY.
URL: https://foffzvwmxnsmbixkilxt.supabase.co

## Tables (list_tables)

| table | rls_enabled |
|---|---|
| public.organizations | true |
| public.roles | true |
| public.candidates | true |
| public.invitations | true |

## Storage

`resumes` bucket created (private), scoped by `organization_id` folder via RLS policy on `storage.objects`.

## Security advisors after fix

Only the two intentional `redeem_invitation` SECURITY DEFINER warnings remain — expected, since candidates
redeem an invitation code without a Supabase Auth account. The `function_search_path_mutable` warnings on
both functions were fixed (`pin_function_search_path` migration).

## flutter analyze

No issues found! (ran in 10.9s)
