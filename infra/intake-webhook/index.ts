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
// Multi-tenant intake note: the submission's `formId` (the Google Form's own
// id — every submitting script sends it, see google-form-apps-script.gs) is
// resolved directly against `intakes.google_form_id`, which carries its own
// organization_id/role_id. This replaced an earlier "assume exactly one
// organisation, fuzzy-match the role title" fallback that only worked for a
// single-tenant deployment — deliberately removed rather than kept as a
// silent default, since guessing the wrong org/role here is exactly the
// "inferred ownership" this project's tenancy model forbids. A submission
// whose form isn't a known, active intake is rejected, not defaulted.
//
// One explicit, narrow exception (LEGACY_FORM_ID below): the original
// hand-built form predates the intakes model and lets an applicant type or
// pick ANY role via a single shared form/field, across two real candidates
// already recorded against two different roles at the same org. Pinning it
// to one intake would silently misroute or reject a real applicant choosing
// a different role than whichever one got picked; retiring it outright was
// a bigger call than this pass — so its old fuzzy-match behavior is kept
// alive, but ONLY for this one specific form id. Every other form (all
// auto-created per intake) always uses the strict lookup above.
//
// Canonicalization note: this function used to generate its own 6-char code
// and write to a separate `invitations` table, polled by a cron
// (`reminder-scheduler`) using its own Gmail-SMTP sender — a second,
// parallel code+email system next to the real one
// (`session/interview_codes.py` + `notifications/workflow.py`, Ticket 21).
// That's gone: this function now only creates the candidate (with
// `role_id`/`intake_id` persisted so the AI pipeline knows what role/campaign
// they applied for) and lets the existing `candidates_resume_uploaded`
// trigger kick off resume processing. Once `candidate_ai_profile.
// processing_status` reaches READY_FOR_INTERVIEW, the
// `candidate_ready_for_interview` trigger takes it from there — generating
// the code and sending the invitation through the one canonical path. The
// `invitations` table and `reminder-scheduler` are deprecated, not deleted,
// in case anything still reads them.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

// See the "One explicit, narrow exception" comment above.
const LEGACY_FORM_ID = "1Kl0zcEoh8Go2PeVFrRoSEg-ddSXZXt2uZ9gREcwTwV0";
const LEGACY_ORGANIZATION_ID = "48f1c20f-c5ba-4d3c-9561-697742973f27"; // CogniHire Demo Co

// Auto-created intake forms ask for a resume LINK, not an upload (Google's
// Forms API can't create file-upload questions at all — see forms.py).
// Without this, resume_path never gets set, the candidates_resume_uploaded
// trigger never fires, and the whole downstream chain (AI profile ->
// auto-invite -> interview code -> email) silently never runs — confirmed
// by an actual end-to-end test, not assumed. Only Google Drive links set to
// "Anyone with the link" are handled: that's a plain unauthenticated fetch,
// no OAuth token involved, since drive.file scope wouldn't grant access to
// a file the app never created anyway. Anything else (private links,
// Dropbox, etc.) fails clearly — resume_link is still saved either way, so
// nothing is lost, just not auto-processed.
function extractDriveFileId(url: string): string | null {
  const patterns = [/\/file\/d\/([a-zA-Z0-9_-]+)/, /[?&]id=([a-zA-Z0-9_-]+)/];
  for (const pattern of patterns) {
    const match = url.match(pattern);
    if (match) return match[1];
  }
  return null;
}

const EXTENSION_BY_CONTENT_TYPE: Record<string, string> = {
  "application/pdf": "pdf",
  "application/msword": "doc",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
};

async function fetchDriveResume(
  driveUrl: string,
): Promise<{ bytes: Uint8Array; filename: string } | { error: string }> {
  const fileId = extractDriveFileId(driveUrl);
  if (!fileId) return { error: "not a recognizable Google Drive link" };

  const response = await fetch(`https://drive.google.com/uc?export=download&id=${fileId}`);
  if (!response.ok) return { error: `Drive fetch failed: HTTP ${response.status}` };

  const contentType = response.headers.get("content-type") ?? "";
  // An unauthenticated fetch of a non-public (or virus-scan-interstitial)
  // file returns an HTML page instead of the file bytes — the one reliable
  // signal available here that the "anyone with the link" fetch didn't
  // actually get the resume.
  if (contentType.includes("text/html")) {
    return { error: "Drive link is not public (\"Anyone with the link\") or requires the virus-scan interstitial" };
  }

  const extension = EXTENSION_BY_CONTENT_TYPE[contentType.split(";")[0].trim()] ?? "pdf";
  const bytes = new Uint8Array(await response.arrayBuffer());
  return { bytes, filename: `resume.${extension}` };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  let body: {
    secret?: string;
    formId?: string;
    name?: string;
    email?: string;
    roleTitle?: string;
    preferredTimeIso?: string;
    resumeBase64?: string;
    resumeFilename?: string;
    phone?: string;
    linkedinUrl?: string;
    yearsExperience?: string;
    resumeLink?: string;
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

  const {
    name, email, roleTitle, preferredTimeIso, resumeBase64, resumeFilename, formId,
    phone, linkedinUrl, yearsExperience, resumeLink,
  } = body;
  if (!formId) {
    return new Response(
      JSON.stringify({ error: "missing formId — this submission cannot be matched to an intake" }),
      { status: 400, headers: { "Content-Type": "application/json" } },
    );
  }
  if (!name || !email || !roleTitle) {
    return new Response(
      JSON.stringify({ error: "missing name, email, or roleTitle" }),
      { status: 400, headers: { "Content-Type": "application/json" } },
    );
  }

  let organizationId: string;
  let roleId: string;
  let intakeId: string | null = null;

  if (formId === LEGACY_FORM_ID) {
    organizationId = LEGACY_ORGANIZATION_ID;
    const { data: matchedRole, error: roleError } = await client
      .from("roles")
      .select("id")
      .eq("organization_id", LEGACY_ORGANIZATION_ID)
      .ilike("title", `%${roleTitle}%`)
      .maybeSingle();
    if (roleError || !matchedRole) {
      return new Response(
        JSON.stringify({ error: `no role matching "${roleTitle}" found for the legacy form's organization` }),
        { status: 404, headers: { "Content-Type": "application/json" } },
      );
    }
    roleId = matchedRole.id;
  } else {
    const { data: intake, error: intakeError } = await client
      .from("intakes")
      .select("id, organization_id, role_id, status")
      .eq("google_form_id", formId)
      .maybeSingle();
    if (intakeError || !intake) {
      return new Response(
        JSON.stringify({ error: `no intake is registered for form ${formId}` }),
        { status: 404, headers: { "Content-Type": "application/json" } },
      );
    }
    if (intake.status !== "active") {
      return new Response(
        JSON.stringify({ error: `intake for form ${formId} is ${intake.status}, not accepting applications` }),
        { status: 409, headers: { "Content-Type": "application/json" } },
      );
    }
    organizationId = intake.organization_id;
    roleId = intake.role_id;
    intakeId = intake.id;
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

  // Upsert on (organization_id, email): a retried Apps Script trigger (or a
  // candidate re-submitting the form) resolves to the SAME candidate row
  // instead of creating a duplicate — this is the fix for the duplicate-
  // candidate/duplicate-code/duplicate-email gap flagged during integration
  // review.
  //
  // The id must be looked up explicitly, not left to Supabase's upsert to
  // "not touch on conflict" — it doesn't do that. `.upsert(row, {onConflict})`
  // updates every column in `row` on a matching conflict, id included, which
  // tried to overwrite an existing candidate's primary key and failed with a
  // foreign key violation the moment that candidate already had a
  // candidate_ai_profile row pointing at their real id (caught via an actual
  // resubmission during testing, not by inspection).
  const { data: existingCandidate } = await client
    .from("candidates")
    .select("id")
    .eq("organization_id", organizationId)
    .eq("email", email)
    .maybeSingle();
  const candidateId = existingCandidate?.id ?? `cand-intake-${crypto.randomUUID()}`;
  let resumePath: string | null = null;
  let resumeFetchWarning: string | null = null;
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
  } else if (resumeLink) {
    const fetched = await fetchDriveResume(resumeLink);
    if ("error" in fetched) {
      // Not fatal: the candidate still gets created with resume_link saved
      // (visible to a recruiter, who can fetch it manually) — only the
      // automatic AI-profile/auto-invite chain doesn't fire. Blocking
      // candidate creation over a resume-fetch failure would be worse: the
      // candidate wouldn't exist at all.
      resumeFetchWarning = fetched.error;
    } else {
      resumePath = `${organizationId}/${candidateId}-${fetched.filename}`;
      const { error: uploadError } = await client.storage
        .from("resumes")
        .upload(resumePath, fetched.bytes, { upsert: true });
      if (uploadError) {
        resumePath = null;
        resumeFetchWarning = `resume upload failed: ${uploadError.message}`;
      }
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
    role_id: roleId,
    intake_id: intakeId,
    preferred_time: preferredTime.toISOString(),
  };
  if (resumePath) {
    candidateRow.resume_path = resumePath;
  }
  // Optional fields — never sent unconditionally, same reasoning as
  // resume_path above: a resubmission missing one of these shouldn't wipe
  // out a value already captured from an earlier submission.
  if (phone) candidateRow.phone = phone;
  if (linkedinUrl) candidateRow.linkedin_url = linkedinUrl;
  if (yearsExperience) candidateRow.years_experience = yearsExperience;
  if (resumeLink) candidateRow.resume_link = resumeLink;

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
    JSON.stringify({ ok: true, candidateId: upserted.id, resumeFetchWarning }),
    { status: 201, headers: { "Content-Type": "application/json" } },
  );
});
