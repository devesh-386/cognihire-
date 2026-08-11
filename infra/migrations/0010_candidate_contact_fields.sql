-- Adds phone, LinkedIn/portfolio, and years-of-experience fields to
-- candidates so the auto-created intake Google Forms can collect them —
-- previously only name/email/resume link/preferred time were captured.
alter table public.candidates
  add column phone text,
  add column linkedin_url text,
  add column years_experience text,
  add column resume_link text;
-- resume_link is deliberately separate from resume_path: resume_path is a
-- Supabase Storage path the candidates_resume_uploaded trigger (0002/0005)
-- reads to fetch the actual file bytes for AI processing. A candidate-
-- supplied external URL (Drive/Dropbox share link) is not that — it's just
-- informational until/unless something fetches and re-uploads it.
