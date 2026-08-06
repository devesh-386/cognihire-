# Ticket 20 — deploying this box (builds on Ticket 9's plan)

Ticket 9 below already covers what Ticket 20 asks for: a VM, HTTPS, env vars,
health checks. Two things were genuinely missing and are now fixed in code —
not just documented:

- **Logging was silently going nowhere.** `main.py` never called
  `logging.basicConfig`, so every `logger.info`/`logger.warning` in the
  pipeline (stage transitions, degraded-mode fallbacks) was swallowed by
  Python's default no-op handler. A deployed box with invisible logs is
  undebuggable mid-demo. Fixed: explicit `basicConfig` at INFO by default,
  `LOG_LEVEL` env var to turn it down.
- **`GET /health` couldn't tell you what was actually configured.** It only
  ever reported the face engine. It now also reports `llm_provider`,
  and `*_set` booleans for `OPENAI_API_KEY` / `SUPABASE_URL` /
  `SUPABASE_SERVICE_ROLE_KEY` — never the values themselves, just whether
  each one is present — so a fresh deploy with a missing secret is
  diagnosable from one `curl`, not a 503 on the first real request.

**Any VM works, Azure included** — Coolify (the deploy mechanism Ticket 9
already specced) is not tied to a provider; point it at an Azure VM's IP
instead of a generic VPS's and every step below is unchanged. Nothing about
this service assumes a specific cloud.

**What I cannot do from here:** provision the VM itself, buy the domain,
enter your `OPENAI_API_KEY` or `SUPABASE_SERVICE_ROLE_KEY` into Coolify's UI,
or otherwise touch your Azure/OpenAI/Supabase accounts — those are real
credentials and a real spend decision, both yours to make. Everything below
this point in Ticket 9's plan is ready to run as soon as you have the VM;
tell me the VM's IP and I can walk the `curl` verification steps in Step 6
with you once it's up.

---

# Ticket 9 — cloud VM (AI Gateway + face service), via Coolify

**Reworked again 2026-08-06 (second pass).** This box is no longer "the machine
that hosts Ollama". It hosts the **AI Gateway** — the FastAPI service that owns
every LLM call, every prompt, and every provider key in the system. Ollama went
from being the point of the VM to being one pluggable provider behind that
gateway.

What changed, and why it matters for this ticket:

- **The clients no longer call an LLM at all.** The Flutter HR app and the
  candidate web app talk only to the gateway. No API key, prompt, model name, or
  provider name exists in any client bundle — which is what makes it safe to ship
  a web build at all (anything in a Flutter web build is visible via view-source).
- **Provider choice is a server env var** (`LLM_PROVIDER=openai|ollama`), so
  switching providers is a redeploy, not a client release.
- **Ollama is now optional for the demo.** With `LLM_PROVIDER=openai` the box does
  not need to run a 7B model at all, which drops the RAM floor substantially (see
  Sizing below). Keep Ollama for offline demo / no-internet / testing.

## What runs on the box

```
VM (Coolify)
 ├── FastAPI AI Gateway  (service/)
 │     ├── /extract-claims   — claim extraction, grounding-gated
 │     ├── /resumes/process  — PDF → text → structured → claims → profile
 │     ├── OpenAI adapter    (default)
 │     └── Ollama adapter    (offline/testing)
 ├── Face service        (same FastAPI process today: /face/analyze)
 └── Reverse proxy / TLS (Coolify handles this)
```

The gateway and the face service are currently **one FastAPI process**
(`service/main.py`). `AI_GATEWAY_URL` is a separate config key on the client side
specifically so they can be split into two deployments later without a client
change.

## Sizing

- **`LLM_PROVIDER=openai` (demo default):** no local model, so 2 vCPU / 4GB is
  enough for the face service + gateway. InsightFace's `buffalo_l` is the main
  memory consumer.
- **`LLM_PROVIDER=ollama`:** still needs 8GB+ for `qwen2.5:7b` alongside the face
  service — Hetzner CX32 (~€13.10/mo) as originally specced.

## Steps

1. **Provision one VPS.** Ubuntu 24.04. Size per the section above.
2. **Install Coolify:**
   ```bash
   ssh root@<VM_IP>
   curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
   ```
   Then open `http://<VM_IP>:8000` to finish setup (create your admin account) —
   Coolify's own UI walks you through pointing a domain at it and issuing itself a
   cert for its dashboard.
3. **Deploy the AI Gateway + face service** (Coolify → New Resource →
   Public/Private Git Repository, pointed at this repo, base directory `service/`):
   - Build pack: **Dockerfile** (uses `service/Dockerfile`)
   - Port: `8000`
   - Domain: e.g. `api.yourdomain.com`
   - Environment variables:
     | var | value | notes |
     |---|---|---|
     | `LLM_PROVIDER` | `openai` | or `ollama` for offline |
     | `OPENAI_API_KEY` | *(your key)* | **set this in Coolify's UI yourself — never commit it** |
     | `OPENAI_MODEL` | `gpt-4o-mini` | optional |
     | `SUPABASE_URL` | `https://foffzvwmxnsmbixkilxt.supabase.co` | for the resume pipeline |
     | `SUPABASE_SERVICE_ROLE_KEY` | *(from Supabase dashboard)* | **set yourself**; bypasses RLS by design |
     | `ALLOWED_ORIGINS` | HR + candidate app origins, comma-separated | leave unset (`*`) until Ticket 13 has them |
   - Enable auto-deploy on push if you want `git push` to redeploy it
4. **(Optional) Deploy Ollama** — only if you want the offline path
   (Coolify → New Resource → Docker Image):
   - Image: `ollama/ollama:latest`, port `11434`
   - Persistent volume at `/root/.ollama` so the pulled model survives redeploys
   - After first deploy, open the container console and run `ollama pull qwen2.5:7b`
   - Set `OLLAMA_BASE_URL` on the gateway to point at it
5. **Tell Supabase where the gateway is** — this is what makes the resume
   trigger fire (see *Resume pipeline* below):
   ```sql
   alter database postgres set app.settings.ai_gateway_url = 'https://api.yourdomain.com';
   ```
6. **Verify:**
   ```bash
   curl https://api.yourdomain.com/health
   curl -X POST https://api.yourdomain.com/extract-claims \
     -H 'Content-Type: application/json' \
     -d '{"document_text":"Led a team of 4 engineers.","source":"smoke"}'
   ```
   The second should return `"kind":"hosted_llm"`. If it returns
   `"kind":"heuristic_rule"` with a `degraded_reason`, the gateway is up but
   OpenAI is not reachable/configured — the reason string says which.
7. **Point the apps at it** — relaunch with:
   ```
   --dart-define=AI_GATEWAY_URL=https://api.yourdomain.com
   --dart-define=FACE_SERVICE_URL=https://api.yourdomain.com
   ```

## Cost

VPS ≈ €13.10/mo (~$14) at the 8GB size, less if running OpenAI-only. Coolify is
free/open-source and runs on the same box. Supabase (Ticket 8) is free tier.
**New:** OpenAI usage is now a running cost — it scales with resumes processed and
interview turns, and did not exist under the all-local design.

---

# Resume pipeline (PDF → text → structured → claims → profile)

Applied to the live project as migrations `candidate_ai_profile` and
`candidate_resume_processing_trigger` (SQL also kept in `infra/migrations/`).

```
Candidate applies (apply-webhook / Google Form)
        ↓
Supabase Storage (resumes bucket) + candidates row
        ↓
DB trigger: candidates_resume_uploaded
        ↓  (creates candidate_ai_profile @ UPLOADED, then pg_net POST)
FastAPI  POST /resumes/process
        │
        ├── deterministic/pdf_extraction      → TEXT_EXTRACTED
        │      ╌╌╌╌╌╌╌╌╌ deterministic ends, AI begins ╌╌╌╌╌╌╌╌╌
        ├── ai/resume_understanding    [AI]   → STRUCTURED     ⟨grounding-gated⟩
        │        └── builds the CANDIDATE KNOWLEDGE PROFILE
        ├── ai/claim_extraction        [AI]   → CLAIMS_READY   ⟨grounding-gated⟩
        └── pipeline/profile_builder          → READY_FOR_INTERVIEW

At interview start (not persisted — see below):
        ai/question_planning  [AI]  → question plan  ⟨grounding-gated⟩
        ai/interview          [AI]  → conversation           (planned)
        ai/evidence_linking   [AI]  → claim ← evidence links (planned)
        ai/report_generation  [AI]  → transparent report     (planned)
```

## The Candidate Knowledge Profile is the centre

`resume_understanding` is the **last stage that sees raw resume text**
(claim extraction aside, which needs the source to gate against). Every stage
after it reads the profile — enforced by
`test_downstream_stages_read_the_profile_not_raw_resume_text`. That is what
makes improving how a candidate is understood a one-stage change, and what
leaves room for embeddings or retrieval to be added as a stage enriching the
profile without any consumer changing.

The profile keeps two categories **structurally distinct**:

- **Grounded facts** (skills, projects, experience, education, certifications,
  identity) — verbatim text the candidate wrote, passed through the grounding
  gate. These are *the candidate's claims*.
- **Inferences** (domains, strengths, estimated focus) — a model's reading.
  "Backend" is not a phrase in most resumes, so these can never pass a
  verbatim gate. Instead each **must cite the grounded values it was derived
  from**, every cited value is itself gated, and an inference whose basis does
  not survive is discarded.

A reviewer looking at "estimated focus: Machine Learning" can always ask
*derived from what?* and get an answer made of the person's own words. Without
that split, a model's opinion would quietly acquire the authority of something
the candidate said.

The package layout *is* the architecture — the boundary is enforced by
`service/test_architecture_boundary.py`, not just described here:

| package | role | rule |
|---|---|---|
| `deterministic/` | PDF extraction, fallback parser, **grounding gate** | may never import `ai/` — the verifier of a model's output cannot itself be a model |
| `ai/` | every stage where a model decides something | reaches a vendor only via `ai/provider.py`; every stage emitting factual claims must pass through the grounding gate |
| `pipeline/` | order + durability (resume processing) | holds no prompts, no credentials |
| `session/` | order + durability (interview lifecycle) | orchestrates `ai/` stages, no AI judgement of its own |

**AI stages built:** resume understanding, claim extraction, question planning,
interview (question + follow-up generation), answer analysis, coverage
tracking.
**Planned:** evidence linking, report generation. Each becomes one module
under `ai/`, and each that emits a factual claim about a person goes through
the same gate.

**The interview engine is now wired end to end.** `session/interview_session.py`
is the orchestrator `ai/interview.py`'s pure functions were always missing: it
loads a candidate's `candidate_ai_profile`, builds a question plan, and drives
`interview.next_turn` / `answer_analysis.analyze` / `coverage_manager.evaluate`
turn by turn, persisting state to two new tables —

- `interview_sessions` — one row per interview: status
  (`not_started → in_progress → complete | abandoned`, enforced by
  `session/state_machine.py`), the question plan, coverage state, and outcomes
  per topic. Unlike `interview_context` and question plans elsewhere in this
  codebase, this plan *is* persisted — it's pinned to one already-started
  session's role/difficulty/duration, not reusable config that could go stale.
- `interview_events` — an append-only, sequence-numbered log of every question,
  answer, analysis, and coverage update, for replay and for the transparent
  report Ticket 13 will read.

Three endpoints on the gateway drive it: `POST /interview/start`,
`POST /interview/answer`, `POST /interview/finish` (early abandon only — a
session that finishes its plan completes itself). The candidate-facing client
never sees the plan, the profile, coverage math, or which provider answered —
only the next question and, on `/interview/answer`, whether a follow-up is
needed.

**Ticket 14 — RC1 acceptance test.** `test_end_to_end.py` drives the real
FastAPI app (`TestClient`, not unit-called functions) through the full chain
— candidate → `/resumes/process` → `/interview-codes/generate` →
`/interview/start` → `/interview/answer` (looped to completion) →
`/interview/report` — against an in-memory fake standing in for the whole
Supabase REST/Storage surface. With no `OPENAI_API_KEY` set (this
environment's default), every AI stage degrades to its fallback before any
network call, so this proves the PLUMBING — every stage's output is actually
persisted and readable by the next one — not prompt quality or cost, which
is Ticket 15 and gated on a real key this environment doesn't have.

Running it found a real bug: `coverage_manager.evaluate` kept an unsupported
topic in `remaining` forever, so a fully degraded run (heuristic
`answer_analysis`, which never claims support — see its docstring) could
never reach `is_complete`. Fixed with `TopicOutcome.attempts` and a
`_MAX_ATTEMPTS_PER_TOPIC = 2` cap: an unsupported topic still gets one retry,
then is written off and reported as unsupported rather than asked forever.
This is a bookkeeping fix inside an existing module, not a new AI stage.

Separately, the `candidates_resume_uploaded` trigger (Google Form/apply →
Storage → webhook stage) was smoke-tested live against the production
Supabase project via `execute_sql` — insert a candidate, confirm a
`candidate_ai_profile` row appears at `UPLOADED`, roll back — since a fully
live run needs the gateway actually deployed somewhere `app.settings.
ai_gateway_url` can reach, which it doesn't yet (that's Ticket 18).

**What's still blocked pending a real environment (not this one):**
zero real candidates/organizations/roles exist in the live project (a real
HR sign-up + role + resume upload is a genuine user action, not something to
fabricate here); no gateway is deployed anywhere Supabase's trigger can
reach; no `OPENAI_API_KEY`/`SUPABASE_SERVICE_ROLE_KEY` exist in this
sandbox to run the service against live infrastructure. Ticket 15 (real
OpenAI) and Ticket 18 (deployment) are what unblock those.

**Ticket 19 — demo environment.** `POST /demo/seed` (`service/demo/seed.py`)
creates everything one demo run needs in one call: a fixed organization
("CogniHire Demo Co"), an HR login (created via the Supabase Admin Auth API
with `user_metadata.organization_id` set, matching `auth_organization_id()`),
three roles, and five candidates with deliberately different resume
qualities (strong all-rounder, average, fresh graduate with no experience,
ML specialist, and a different-stack backend developer) — so a demo shows
the interview actually adapting to who it's asking, not one canned
transcript. Every candidate is run through the real, unmodified
`profile_builder.process_candidate_resume` pipeline, the same path a real
candidate's resume takes; nothing about the AI pipeline changes for this
ticket, per the architecture freeze. Seeding is idempotent — org/roles/
candidates are found by name/email and reused, never duplicated, so it's
safe to call more than once.

`POST /demo/reset` clears interview sessions, their event logs, and interview
codes for the demo org, then re-seeds fresh codes over the same
candidates/profiles/roles — "Delete Sessions → Delete Reports → Restore
Initial State" without touching anything that took real pipeline work to
produce. `service/test_demo_seed.py` (4 tests) proves both are idempotent
and that reset preserves exactly what it should.

**Ticket 21 — email automation.** `service/notifications/` (deliberately not
named `email/` — that shadows Python's stdlib `email` package, which
`provider.py` itself imports from):

- **`provider.py`** — the boundary. [EmailProvider] is a `Protocol`;
  [SmtpEmailProvider], [SendGridEmailProvider], and
  [AzureCommunicationEmailProvider] each implement it over their own
  transport (SMTP, SendGrid's REST API, ACS's REST API — no new SDK
  dependency for either). `get_provider()` reads `EMAIL_PROVIDER` (default
  `smtp`) and falls back to [NullEmailProvider] — which always reports a
  real failure, never a fake success — when the selected provider's
  credentials aren't set. Nothing above this file knows which one is active.
- **`templates.py`** — pure functions building the invitation and reminder
  copy; no I/O, so content can be tested without a provider or the database.
- **`store.py`** — REST access to the new `interview_code_emails` table
  (one row per `(code_id, email_type)`, unique-constrained — the database
  itself is what makes "don't duplicate a reminder" enforceable, not just
  application logic).
- **`delivery.py`** — `attempt_send`: up to 3 attempts with exponential
  backoff (1s, 2s), persisting `status`/`attempts`/`last_error` after every
  attempt. Never raises — a failure ends up recorded as `status='failed'`,
  never an exception the caller has to special-case, so a failed email can
  never affect interview scheduling.
- **`workflow.py`** — `send_invitation_for_code` (called automatically from
  `/interview-codes/generate`; idempotent — a second call for the same code
  returns the existing row untouched), `resend_invitation` (the HR desktop's
  explicit action — always sends again), and `send_due_reminders` (the
  scheduler entrypoint — Ticket 21's parallel of Ticket 12's
  `reminder-scheduler` Edge Function, for the interview-code system instead
  of the legacy invitations flow; scans every `active` code and sends
  whichever reminder, 1-hour or 30-minute, is currently within its window).

New routes: `GET /interview-codes/{id}/emails` (the HR desktop's Email
Status list), `POST /interview-codes/resend-invitation`,
`POST /email/send-due-reminders`. `GenerateCodeRequest` gained an optional
`scheduled_at`, which doubles as `window_start` (the code isn't redeemable
before it) and as what the invitation/reminder emails tell the candidate.

**Not deployed:** nothing polls `/email/send-due-reminders` yet — that needs
either a `pg_cron` job calling it (same shape as Ticket 12's, pointed at
this route instead) or an external scheduler, both of which need the
gateway actually deployed somewhere reachable (Ticket 20). **Not
configured:** every `EMAIL_PROVIDER` needs real credentials
(`SMTP_HOST`/`SMTP_USERNAME`/`SMTP_PASSWORD`, or `SENDGRID_API_KEY`, or
`ACS_ENDPOINT`/`ACS_ACCESS_KEY`) plus `EMAIL_FROM_ADDRESS` and `PORTAL_URL`
— none exist in this sandbox, so every send in this environment resolves to
[NullEmailProvider] and reports `status='failed', last_error="... not
configured"`. That is the intended, honest behavior, not a bug — the same
"admit what can't be checked" rule the AI pipeline follows for a missing
`OPENAI_API_KEY`. `service/test_email_workflow.py` (7 tests) and
`service/test_email_routes.py` (3 tests) cover success, provider failure,
retry-then-succeed, duplicate-reminder prevention, and resend — all against
a fake provider/store, so they exercise the real logic without needing
those credentials.

**Interview codes** (`session/interview_codes.py`, `interview_codes` table):
the candidate portal never sees a candidate id, organization id, or role —
only a code an HR reviewer generated via `POST /interview-codes/generate`.
`POST /interview/start` now takes `{code}` (not raw ids). A code is single-
use by construction: `start_with_code` resumes an `in_progress` session
under the same code (a refresh or dropped connection doesn't cost an
attempt or lose progress), rejects a code whose session is already
`complete`, and enforces `max_attempts`, `expires_at`, and an optional
`window_start`/`window_end`. Generation is centralized server-side per an
explicit decision: the HR desktop is a caller, never a source of truth, so
the same endpoint can later be triggered by the Google Form automation in
Phase 5 without any client change.

**Candidate Portal (`portal/`, Vercel):** a Next.js app that talks to nothing
but `/interview-codes` and `/interview/*`
([lib/gateway.js](../portal/lib/gateway.js)). Same "thin, dumb client" rule as
the Flutter app: it never sees a plan, a profile, or a provider name — only
the turn the gateway sends. The candidate enters a code on `/`; `/interview`
runs a camera/microphone permission check (`getUserMedia`) before starting —
this is a device check, not identity verification; there is no reference
photo for the portal to check a candidate against yet, so that step
deliberately isn't faked. Email delivery of codes is still manual (the HR
desktop shows a code to copy and send by hand) — automated delivery is
scoped separately.

**HR Desktop — "AI Interviews" tab:** `lib/features/interview_sessions/` reads
`interview_sessions` / `interview_events` directly from Supabase (RLS-scoped
to the reviewer's organization, same pattern as `SupabaseRoleStore`) and
renders each session's coverage and full transcript. This is read-only and
deliberately separate from the app's original local `AuditStore`-backed
"Sessions"/"Candidates" screens — those record sessions run on-device with
face verification; this reads sessions the *backend* ran through the
candidate portal. The two are not merged, because they are genuinely two
different interview mechanisms this codebase currently supports, and
conflating them would misattribute which one produced which evidence.

**Evidence linking and report generation** (`ai/evidence_linking.py`,
`ai/report_generation.py`) are the last two pipeline stages, and neither
calls a model — every fact they touch was already decided and gated when the
answer that produced it was analyzed live. `evidence_linking.build_links`
walks a session's `interview_events` log and pairs each question/follow-up
with its answer and verdict; `report_generation.build_report` reduces that to
one row per planned topic (using a follow-up's verdict over the original
question's, since it's a second, more informed judgement of the same claim),
plus which planner-proposed topics were discarded for lacking a grounded
claim. `GET /interview/report/{session_id}` exposes it, and the HR desktop's
"AI Interviews" detail screen renders it above the raw transcript — still no
score, no ranking: a topic with no outcome is one the interview never
reached, not a failing grade.

**Why resume understanding is AI rather than a parser:** a regex knows
"Skills" is a heading; it does not know that "shipped a Flutter app to the
Play Store" is evidence of release engineering. That understanding is the
product. The deterministic parser remains as the fallback when a provider is
unreachable — `understanding_kind` on the profile records which one actually
ran.

**`interview_context` and the question plan are deliberately not stored.** Both
depend on the selected role, duration, difficulty, and prompt version — all of
which change after a resume is processed — so both are built fresh at
interview start from the profile plus live HR configuration. Storing either
would guarantee serving a stale one.

**Planning is separate from asking.** `question_planning` decides what the
interview covers and in what order; only then does the interview stage turn
that into conversation. An interview model left to invent its own questions
produces a session nobody can reproduce or defend — coverage depends on
whatever the model happened to focus on, and "why was this asked?" has no
answer beyond the transcript. Splitting them makes the interview inspectable
*before* it happens, and lets coverage and conversational quality be improved
independently.

**The trigger is fail-safe by design.** It always creates the profile row, but
the `pg_net` notification is best-effort and swallows every error — a candidate
must never lose their application because an internal AI service was down. The
consequence: *an unreachable gateway is invisible at the trigger*. The profile
row is the queue — anything sitting at `UPLOADED` is unprocessed work. Until
step 5 above is done (`app.settings.ai_gateway_url` unset), **every** profile
will sit at `UPLOADED`; that is expected, not a bug.

---

# Ticket 11 — candidate intake → Supabase

**Reworked 2026-08-06**: Devesh has no way to act on Google-account-gated or
paid-account-gated setup steps right now (out of everyone's control at this
moment — those genuinely need his own accounts). So the **default path is now
a self-hosted "Apply" page** (`lib/main_apply.dart`, `ApplyScreen`) that needs
*zero* external accounts — no Google, no Apps Script, nothing for anyone to
sign up for. It posts straight to a new public `apply-webhook` Edge Function.
The original Google Form path (`intake-webhook`) still exists below as an
alternative for later, if a real Google Form is ever wanted instead/as well —
both write to the same `candidates`/`invitations` tables, so either or both
can run at once.

## Self-hosted apply page (recommended, no setup needed)

Already built and deployed:
- `apply-webhook` Edge Function — public, no shared secret (anything shipped
  in a Flutter *web build* is visible via view-source, so a client-side
  "secret" wouldn't secure anything anyway — accepted tradeoff for a
  demo-scoped deployment). Validates the role exists, uploads the résumé,
  creates the candidate + a scheduled invitation exactly like the Google Form
  path does.
- `list_open_roles()` — a public read-only RPC so the page can populate a role
  dropdown without needing a signed-in HR session.
- `lib/features/apply/apply_screen.dart` + `lib/main_apply.dart` — the page
  itself: name, email, role dropdown, preferred time, optional résumé upload.

Run it locally: `flutter run -d chrome -t lib/main_apply.dart` (or via
`.claude/launch.json`'s `cognihire-apply` config, port 8768). Once an HR
account exists and has created at least one role, this page works standalone
— share its URL with candidates, no further setup.

Sanity-checked live against the deployed function:
```
curl -s -X POST https://foffzvwmxnsmbixkilxt.supabase.co/functions/v1/apply-webhook \
  -H "Content-Type: application/json" -d '{}'
# {"error":"missing name, email, roleId, or preferredTimeIso"}
```

## Google Form alternative (optional, needs a Google account)

If a real Google Form is wanted instead or as well, `intake-webhook` (already
deployed) supports it — same result, different intake surface.

### 1. Create the Google Form

Fields, exact titles (the Apps Script matches on these):
- **Full name** — short answer
- **Email** — short answer, "Response validation" → email
- **Which role are you applying for?** — short answer or dropdown. Must match an
  existing `Role.title` in your organisation *exactly* (case-insensitive) — HR
  creates the role in the app first, then you copy its title into the form.
- **Preferred interview time** — Date question with "Include time" on
- **Resume** — File upload, restrict to PDF/DOC/DOCX, max 1 file

### 2. Wire the Apps Script

1. In the Form, **⋮ → Script editor** (or Extensions → Apps Script).
2. Paste in `infra/google-form-apps-script.gs`.
3. Replace `WEBHOOK_SECRET` with: `wauVZueHxrCg-_ezPuqrZEjaildmrh_AGl-jdJmkxYg`
   (already set as the Edge Function's `INTAKE_WEBHOOK_SECRET` secret below —
   keep both in sync if you rotate it).
4. **Triggers** (clock icon in the left sidebar) → **+ Add Trigger** → function
   `onFormSubmit`, event source **From form**, event type **On form submit**.
   Authorize when prompted (it needs Drive access to read the uploaded résumé).

### 3. Set the Edge Function's secret (optional)

`INTAKE_WEBHOOK_SECRET` is already set. `INTAKE_ORGANIZATION_ID` is now
**optional** — `intake-webhook` auto-resolves to the sole row in
`organizations` once one HR account has registered, so for a single-org demo
there's nothing left to set here at all. Only needed if more than one
organisation ever exists on this project:

```bash
supabase secrets set --project-ref foffzvwmxnsmbixkilxt \
  INTAKE_ORGANIZATION_ID=<the id you want>
```

Find an org's id if you ever need it:

```bash
supabase --project-ref foffzvwmxnsmbixkilxt db query \
  "select id, name from organizations;"
```

### 4. Verify

Submit the Google Form once with a role title that matches a real role you created.
Check it landed:

```bash
supabase --project-ref foffzvwmxnsmbixkilxt db query \
  "select c.name, i.status, i.scheduled_at, i.code_send_at from invitations i join candidates c on c.id = i.candidate_id order by i.created_at desc limit 1;"
```

Or check the function's own logs in the Supabase Dashboard → Edge Functions →
`intake-webhook` → Logs, if the submission didn't show up (wrong role title is the
most likely miss — it's an exact-title match against your roles table).

---

# Ticket 12 — scheduler + staged reminder emails

`reminder-scheduler` (deployed) is polled every 5 minutes by a `pg_cron` job
(`schedule_reminder_cron` migration) via `pg_net`. Each run: sends the redemption
code for any `scheduled` invitation past its `code_send_at` (flips it to `pending`),
then sends a plain reminder for any `pending` invitation past its `reminder_send_at`
— both are no-ops once already sent (`code_sent_at`/`reminder_sent_at` gate them),
so a slow run or a retry never double-sends.

## Set the two required secrets

The function needs your Gmail credentials — **set these yourself**, don't paste the
App Password to me:

```bash
supabase secrets set --project-ref foffzvwmxnsmbixkilxt \
  GMAIL_ADDRESS=you@gmail.com \
  GMAIL_APP_PASSWORD=your-16-character-app-password \
  SCHEDULER_SECRET=Cpv4T5gCBe6FCwThoI25NHeisKU5vxm07Sw0XdC_lxY
```

`SCHEDULER_SECRET` must match the literal baked into the `schedule_reminder_cron`
migration's cron job body exactly — if you ever rotate it, update both.
`SUPABASE_URL`/`SUPABASE_SERVICE_ROLE_KEY` are injected automatically for every
Edge Function; nothing to set there.

## Verify

Confirm the cron job is registered and check its recent run history:

```bash
supabase --project-ref foffzvwmxnsmbixkilxt db query \
  "select jobname, schedule, active from cron.job;"
supabase --project-ref foffzvwmxnsmbixkilxt db query \
  "select status, return_message, start_time from cron.job_run_details order by start_time desc limit 5;"
```

Or trigger one run immediately without waiting for the next 5-minute tick:

```bash
curl -X POST https://foffzvwmxnsmbixkilxt.supabase.co/functions/v1/reminder-scheduler \
  -H "x-scheduler-secret: Cpv4T5gCBe6FCwThoI25NHeisKU5vxm07Sw0XdC_lxY"
```

A real end-to-end check needs an invitation with `code_send_at` already in the
past — easiest via the Google Form (Ticket 11) with a preferred time an hour from
now, or by hand-editing a test row's `code_send_at`.
