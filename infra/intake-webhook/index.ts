// Ticket 11 — receives one Google Form submission (via the Apps Script
// trigger in infra/google-form-apps-script.gs) and turns it into a
// candidate + a scheduled invitation.
//
// Auth: this is called by Apps Script, which cannot mint a Supabase user
// JWT, so verify_jwt is off for this function and a shared secret
// (INTAKE_WEBHOOK_SECRET) is checked instead — the standard pattern for a
// server-to-server webhook with no interactive user. The service-role key
// is used for the actual writes, deliberately bypassing the org-scoped RLS
// that protects every other write path in this project, because intake has
// no signed-in HR session to scope by.
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
  if (!name || !email || !roleTitle || !preferredTimeIso) {
    return new Response(
      JSON.stringify({ error: "missing name, email, roleTitle, or preferredTimeIso" }),
      { status: 400, headers: { "Content-Type": "application/json" } },
    );
  }

  const scheduledAt = new Date(preferredTimeIso);
  if (Number.isNaN(scheduledAt.getTime())) {
    return new Response(JSON.stringify({ error: "preferredTimeIso is not a valid instant" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
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

  const { error: candidateError } = await client.from("candidates").insert({
    id: candidateId,
    organization_id: organizationId,
    name,
    email,
    resume_path: resumePath,
  });
  if (candidateError) {
    return new Response(JSON.stringify({ error: candidateError.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Codes are six unambiguous characters (matches the Dart-side
  // generateInvitationCode alphabet in invitation.dart) — generated now, but
  // not delivered to the candidate until Ticket 12's reminder-scheduler
  // sends it at code_send_at.
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const code = Array.from(
    crypto.getRandomValues(new Uint8Array(6)),
    (b) => alphabet[b % alphabet.length],
  ).join("");

  const oneHourMs = 60 * 60 * 1000;
  const codeSendAt = new Date(scheduledAt.getTime() - oneHourMs);
  const reminderSendAt = new Date(scheduledAt.getTime() - oneHourMs / 2);

  const invitationId = `inv-intake-${crypto.randomUUID()}`;
  const { error: invitationError } = await client.from("invitations").insert({
    id: invitationId,
    organization_id: organizationId,
    candidate_id: candidateId,
    role_id: role.id,
    code,
    status: "scheduled",
    scheduled_at: scheduledAt.toISOString(),
    code_send_at: codeSendAt.toISOString(),
    reminder_send_at: reminderSendAt.toISOString(),
  });
  if (invitationError) {
    return new Response(JSON.stringify({ error: invitationError.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  return new Response(
    JSON.stringify({ ok: true, candidateId, invitationId }),
    { status: 201, headers: { "Content-Type": "application/json" } },
  );
});
