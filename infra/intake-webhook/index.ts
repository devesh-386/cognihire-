// Ticket 11 — receives one Google Form submission (via the Apps Script
// trigger in infra/google-form-apps-script.gs) and creates a candidate.
//
// Auth: this is called by Apps Script, which cannot mint a Supabase user
// JWT, so verify_jwt is off for this function and a shared secret
// (INTAKE_WEBHOOK_SECRET) is checked instead — the standard pattern for a
// server-to-server webhook with no interactive user. The service-role key
// is used for the actual writes, deliberately bypassing the org-scoped RLS
// that protects every other write path in this project, because intake has
// no signed-in HR session to scope by.
//
// Canonicalization note: this function used to generate its own 6-char code
// and write to a separate `invitations` table, polled by a cron
// (`reminder-scheduler`) using its own Gmail-SMTP sender — a second,
// parallel code+email system next to the real one
// (`session/interview_codes.py` + `notifications/workflow.py`, Ticket 21).
// That's gone: this function now only creates the candidate (with
// `role_id` persisted so the AI pipeline knows what role they applied for)
// and lets the existing `candidates_resume_uploaded` trigger kick off resume
// processing. Once `candidate_ai_profile.processing_status` reaches
// READY_FOR_INTERVIEW, the `candidate_ready_for_interview` trigger takes it
// from there — generating the code and sending the invitation through the
// one canonical path. The `invitations` table and `reminder-scheduler` are
// deprecated, not deleted, in case anything still reads them.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  let body: {
    secret?: string;
    name?: string;
    email?: string;
    roleTitle?: string;
    preferredTimeIso?: string;
    resumeBase64?: string;
    resumeFilename?: string;
  };
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "invalid JSON body" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  const expectedSecret = Deno.env.get("INTAKE_WEBHOOK_SECRET");
  if (!expectedSecret || body.secret !== expectedSecret) {
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  const client = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // INTAKE_ORGANIZATION_ID is optional: for the common single-organisation
  // demo deployment, there's exactly one row in organizations and no secret
  // needs setting at all. Only ambiguous (multi-org) or empty (no HR account
  // registered yet) deployments require the explicit secret.
  let organizationId = Deno.env.get("INTAKE_ORGANIZATION_ID");
  if (!organizationId) {
    const { data: orgs, error: orgsError } = await client
      .from("organizations")
      .select("id");
    if (orgsError || !orgs || orgs.length !== 1) {
      return new Response(
        JSON.stringify({
          error: orgs && orgs.length > 1
            ? "multiple organisations exist — set INTAKE_ORGANIZATION_ID explicitly"
            : "no organisation registered yet — an HR account must sign up first",
        }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }
    organizationId = orgs[0].id;
  }

  const { name, email, roleTitle, preferredTimeIso, resumeBase64, resumeFilename } = body;
  if (!name || !email || !roleTitle) {
    return new Response(
      JSON.stringify({ error: "missing name, email, or roleTitle" }),
      { status: 400, headers: { "Content-Type": "application/json" } },
    );
  }

  // Required now that the interview code is generated with window_start/
  // window_end pinned to this value (see main.py's auto-invite endpoint) —
  // a candidate with no preferred_time would get a code that never becomes
  // redeemable, since window_start would be null and generate() has nothing
  // to base window_end on either.
  let preferredTime: Date | null = null;
  if (preferredTimeIso) {
    const parsed = new Date(preferredTimeIso);
    if (!isNaN(parsed.getTime())) preferredTime = parsed;
  }
  if (!preferredTime) {
    return new Response(
      JSON.stringify({ error: "missing or invalid preferredTimeIso" }),
      { status: 400, headers: { "Content-Type": "application/json" } },
    );
  }

  const { data: role, error: roleError } = await client
    .from("roles")
    .select("id")
    .eq("organization_id", organizationId)
    .ilike("title", roleTitle)
    .maybeSingle();
  if (roleError || !role) {
    return new Response(
      JSON.stringify({ error: `no role matching "${roleTitle}" in this organisation` }),
      { status: 422, headers: { "Content-Type": "application/json" } },
    );
  }

  // Upsert on (organization_id, email): a retried Apps Script trigger (or a
  // candidate re-submitting the form) resolves to the SAME candidate row
  // instead of creating a duplicate — this is the fix for the duplicate-
  // candidate/duplicate-code/duplicate-email gap flagged during integration
  // review. id is only set on first insert; on conflict it's left alone.
  const candidateId = `cand-intake-${crypto.randomUUID()}`;
  let resumePath: string | null = null;
  if (resumeBase64 && resumeFilename) {
    resumePath = `${organizationId}/${candidateId}-${resumeFilename}`;
    const bytes = Uint8Array.from(atob(resumeBase64), (c) => c.charCodeAt(0));
    const { error: uploadError } = await client.storage
      .from("resumes")
      .upload(resumePath, bytes, { upsert: false });
    if (uploadError) {
      return new Response(
        JSON.stringify({ error: `resume upload failed: ${uploadError.message}` }),
        { status: 500, headers: { "Content-Type": "application/json" } },
      );
    }
  }

  // resume_path is only written when this submission actually carried a
  // resume. Including it unconditionally would send `null` on a
  // resume-less resubmission and wipe the resume the candidate already
  // uploaded — and because the resume trigger returns early on a null
  // resume_path, nothing would reprocess it, leaving them silently stuck
  // with no AI profile and no route to an interview code.
  const candidateRow: Record<string, unknown> = {
    id: candidateId,
    organization_id: organizationId,
    name,
    email,
    role_id: role.id,
    preferred_time: preferredTime.toISOString(),
  };
  if (resumePath) {
    candidateRow.resume_path = resumePath;
  }

  const { data: upserted, error: candidateError } = await client
    .from("candidates")
    .upsert(candidateRow, { onConflict: "organization_id,email" })
    .select("id")
    .single();
  if (candidateError) {
    return new Response(JSON.stringify({ error: candidateError.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  // The candidates_resume_uploaded trigger (0002/0005) fires on this insert
  // or update (AFTER INSERT OR UPDATE OF resume_path) and kicks off resume
  // processing; the candidate_ready_for_interview trigger takes it from
  // READY_FOR_INTERVIEW to a code + invitation email automatically.
  return new Response(
    JSON.stringify({ ok: true, candidateId: upserted.id }),
    { status: 201, headers: { "Content-Type": "application/json" } },
  );
});
