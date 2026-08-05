// Public counterpart to intake-webhook, for the self-hosted "Apply" page
// (lib/main_apply.dart) — replaces the Google Form dependency for anyone who
// doesn't want to set one up. Called directly from a candidate's browser, so
// unlike intake-webhook there is no shared secret: anything shipped in a
// Flutter web build is visible to any visitor via view-source, so a "secret"
// baked into that build secures nothing. Accepted tradeoff for a demo-scoped
// deployment — see infra/README.md's Ticket 11 section.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "method not allowed" }, 405);
  }

  let body: {
    name?: string;
    email?: string;
    roleId?: string;
    preferredTimeIso?: string;
    resumeBase64?: string;
    resumeFilename?: string;
  };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }

  const { name, email, roleId, preferredTimeIso, resumeBase64, resumeFilename } = body;
  if (!name || !email || !roleId || !preferredTimeIso) {
    return json({ error: "missing name, email, roleId, or preferredTimeIso" }, 400);
  }

  const scheduledAt = new Date(preferredTimeIso);
  if (Number.isNaN(scheduledAt.getTime())) {
    return json({ error: "preferredTimeIso is not a valid instant" }, 400);
  }
  if (scheduledAt.getTime() < Date.now()) {
    return json({ error: "preferredTimeIso is in the past" }, 400);
  }

  const client = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // roleId (not roleTitle) here — the apply page fetches the real id list via
  // the public list_open_roles() RPC, so there's no title-matching ambiguity.
  const { data: role, error: roleError } = await client
    .from("roles")
    .select("id, organization_id")
    .eq("id", roleId)
    .maybeSingle();
  if (roleError || !role) {
    return json({ error: `no such role "${roleId}"` }, 422);
  }
  const organizationId = role.organization_id as string;

  const candidateId = `cand-apply-${crypto.randomUUID()}`;
  let resumePath: string | null = null;
  if (resumeBase64 && resumeFilename) {
    resumePath = `${organizationId}/${candidateId}-${resumeFilename}`;
    const bytes = Uint8Array.from(atob(resumeBase64), (c) => c.charCodeAt(0));
    const { error: uploadError } = await client.storage
      .from("resumes")
      .upload(resumePath, bytes, { upsert: false });
    if (uploadError) {
      return json({ error: `resume upload failed: ${uploadError.message}` }, 500);
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
    return json({ error: candidateError.message }, 500);
  }

  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const code = Array.from(
    crypto.getRandomValues(new Uint8Array(6)),
    (b) => alphabet[b % alphabet.length],
  ).join("");

  const oneHourMs = 60 * 60 * 1000;
  const codeSendAt = new Date(scheduledAt.getTime() - oneHourMs);
  const reminderSendAt = new Date(scheduledAt.getTime() - oneHourMs / 2);

  const invitationId = `inv-apply-${crypto.randomUUID()}`;
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
    return json({ error: invitationError.message }, 500);
  }

  return json({ ok: true, candidateId, invitationId }, 201);
});
