-- candidate_ai_profile — everything the AI knows about a candidate.
--
-- Deliberately broader than "resume extraction": this is the single AI source
-- of truth, and it is expected to grow (embeddings, ML-derived scores, weak
-- areas). Naming it for the extraction step would have made every later
-- addition look like it did not belong.
--
-- What is NOT here, on purpose: `interview_context`. Context depends on the
-- selected role, interview duration, difficulty, and the current prompt
-- version — all of which change independently of the resume. Persisting it
-- would mean serving a stale context the first time HR changes a setting, so
-- it is assembled fresh at interview start from this profile plus live HR
-- configuration.

create table public.candidate_ai_profile (
  id text primary key default (gen_random_uuid())::text,
  organization_id text not null references public.organizations(id),
  candidate_id text not null unique references public.candidates(id) on delete cascade,

  -- Pipeline position. Named for the stage that COMPLETED, so a stuck profile
  -- says how far it got rather than only that it is not done.
  --   UPLOADED             — row exists, PDF not yet read
  --   TEXT_EXTRACTED       — resume_text populated
  --   STRUCTURED           — structured_resume populated
  --   CLAIMS_READY         — claims populated
  --   READY_FOR_INTERVIEW  — profile complete, interview may start
  --   FAILED               — see error; the stage it died at is the last one reached
  processing_status text not null default 'UPLOADED'
    check (processing_status in (
      'UPLOADED', 'TEXT_EXTRACTED', 'STRUCTURED',
      'CLAIMS_READY', 'READY_FOR_INTERVIEW', 'FAILED'
    )),

  -- Stage 1 output: raw text lifted out of the PDF, unmodified.
  resume_text text,

  -- Stage 2 output (AI: ai/resume_understanding.py) — the CANONICAL candidate
  -- object that every downstream AI stage reads instead of the resume text.
  --
  -- Carries two structurally distinct categories:
  --   grounded facts (identity, skills, technologies, projects, experience,
  --     education, certifications) — verbatim, grounding-gated
  --   inferences (domains, strengths, estimated_focus) — a model's reading,
  --     each citing the grounded values it was derived from
  -- An inference whose basis does not survive the gate is discarded, so a
  -- model's opinion never acquires the authority of something the candidate
  -- said. See ai/knowledge_profile.py.
  knowledge_profile jsonb,

  -- Which mechanism produced structured_resume. A reviewer must never have to
  -- guess whether a model or a text rule read the resume.
  understanding_kind text
    check (understanding_kind is null or understanding_kind in
      ('hosted_llm', 'local_llm', 'heuristic_rule')),
  understanding_degraded_reason text,

  -- Denormalised out of structured_resume so HR can filter/sort without
  -- unpacking JSON. Written by the same stage that writes structured_resume.
  skills text[] not null default '{}',
  projects text[] not null default '{}',
  experience jsonb,

  -- Stage 3 output: [{id, text, source, skill}] from the AI gateway's
  -- grounding-gated extractor. Only text present verbatim in the resume
  -- survives to here.
  claims jsonb,
  claim_extraction_kind text
    check (claim_extraction_kind is null or claim_extraction_kind in
      ('hosted_llm', 'local_llm', 'heuristic_rule')),
  -- Non-null when the extractor could not use the requested provider and fell
  -- back. Kept so the reviewer UI can say which mechanism actually ran rather
  -- than implying a model did.
  degraded_reason text,

  -- Reserved for the embeddings stage (pgvector lives in infra/postgres, not
  -- here yet). Nullable and unused until then.
  embedding_id text,

  -- Non-null iff processing_status = 'FAILED'.
  error text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index candidate_ai_profile_org_status_idx
  on public.candidate_ai_profile (organization_id, processing_status);

alter table public.candidate_ai_profile enable row level security;

-- Matches the existing candidates/roles/invitations shape exactly
-- (auth_organization_id(), not a hand-rolled JWT lookup).
create policy "org members read own candidate profiles"
  on public.candidate_ai_profile for select
  using (organization_id = auth_organization_id());

create policy "org members write own candidate profiles"
  on public.candidate_ai_profile for insert
  with check (organization_id = auth_organization_id());

create policy "org members update own candidate profiles"
  on public.candidate_ai_profile for update
  using (organization_id = auth_organization_id());

-- The backend writes with the service-role key, which bypasses RLS; these
-- policies exist for the HR app's own reads.

create or replace function public.touch_candidate_ai_profile()
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

create trigger candidate_ai_profile_touch
  before update on public.candidate_ai_profile
  for each row execute function public.touch_candidate_ai_profile();
