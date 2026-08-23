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

// Résumés are PDF/DOC/DOCX (lib/features/apply/apply_screen.dart's picker
// allows exactly those three). 5MB is well past any real CV and well short
// of what it takes to make the decode below hurt.
const MAX_RESUME_BYTES = 5 * 1024 * 1024;
// base64 is 4 characters per 3 bytes; checked against the *encoded* length
// so an oversized payload is rejected before `atob` ever allocates it.
const MAX_RESUME_BASE64_CHARS = Math.ceil(MAX_RESUME_BYTES / 3) * 4 + 4;
const ALLOWED_RESUME_EXTENSIONS = ["pdf", "doc", "docx"];

/** The stored name for an uploaded résumé, or null if it isn't acceptable.
 *
 * This value is not ours: it is whatever the candidate's browser called the
 * file, and it used to go straight into the storage key
 * (`${organizationId}/${candidateId}-${resumeFilename}`) with no check at
 * all. Two things fall out of that. The key itself accepts `../` segments.
 * And the last segment of that key is what the gateway hands back in a
 * `Content-Disposition: inline; filename="..."` header
 * (`/candidates/{id}/resume`), so a quote or a newline in it is a header
 * injection with a several-week delay between upload and trigger.
 *
 * Rejected rather than rewritten: silently renaming someone's file and
 * carrying on is the kind of thing nobody notices until they're looking for
 * a résumé that isn't where they expect. A candidate whose file has an odd
 * name gets told to rename it.
 */
function storedResumeName(rawFilename: string): string | null {
  // Strip any directory component the client sent, on both separators —
  // this is a *file* name, and the caller decides the directory, not the
  // uploader.
  const base = rawFilename.split(/[/\\]/).pop() ?? "";
  if (base.length === 0 || base.length > 100) return null;
  // Allowlist, not a denylist of bad characters: the set of things that
  // are safe in a storage key AND in a quoted header parameter is small
  // and easy to name, while the set of things that aren't is open-ended.
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(base)) return null;
  // No leading dot (handled above), and no `..` anywhere, which the
  // character class alone would still permit.
  if (base.includes("..")) return null;
  const extension = base.split(".").pop()?.toLowerCase() ?? "";
  if (!ALLOWED_RESUME_EXTENSIONS.includes(extension)) return null;
  return base;
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
    if (resumeBase64.length > MAX_RESUME_BASE64_CHARS) {
      return json({ error: "résumé is larger than 5MB" }, 413);
    }
    const storedName = storedResumeName(resumeFilename);
    if (storedName === null) {
      return json({
        error:
          "résumé filename must be letters, digits, dots, dashes or underscores, " +
          "and end in .pdf, .doc or .docx — please rename the file and try again",
      }, 422);
    }

    // `atob` throws on anything that isn't valid base64. Uncaught, that was
    // an unhandled rejection and a 500 with a stack trace for what is
    // plainly a bad request.
    let bytes: Uint8Array;
    try {
      bytes = Uint8Array.from(atob(resumeBase64), (c) => c.charCodeAt(0));
    } catch {
      return json({ error: "résumé is not valid base64" }, 400);
    }
    // The encoded-length check above is an upper bound on the decoded size,
    // not the decoded size itself. Check what we actually got.
    if (bytes.length > MAX_RESUME_BYTES) {
      return json({ error: "résumé is larger than 5MB" }, 413);
    }
    if (bytes.length === 0) {
      return json({ error: "résumé file is empty" }, 400);
    }

    resumePath = `${organizationId}/${candidateId}-${storedName}`;
    const { error: uploadError } = await client.storage
      .from("resumes")
      .upload(resumePath, bytes, { upsert: false });
    if (uploadError) {
      // Logged, not returned: same reasoning as the insert failures below.
      // The storage error text names bucket paths and internal object keys,
      // and the caller here is unauthenticated.
      console.error(`resume upload failed for ${resumePath}: ${uploadError.message}`);
      return json({ error: "could not store the résumé" }, 500);
    }
  }

  // Storage has already been written to at this point, so every failure
  // below has to take the uploaded object back out with it. Without this,
  // re-submitting the same application — which `candidates_org_email_unique`
  // guarantees will fail — uploaded a fresh résumé and then abandoned it,
  // every single time. One email address, repeated forever, is unbounded
  // growth in the bucket with no matching row anywhere to find it by.
  async function discardOrphanedResume() {
    if (resumePath === null) return;
    const { error } = await client.storage.from("resumes").remove([resumePath]);
    if (error) {
      // Worth knowing about (it means an orphan really was left behind) but
      // not worth failing the candidate's application over — the request
      // has already failed for its own reason, which is what they need told.
      console.error(`could not remove orphaned resume ${resumePath}: ${error.message}`);
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
    await discardOrphanedResume();
    // 23505 = unique_violation, i.e. candidates_org_email_unique: this
    // person has already applied to this organization. That is an ordinary
    // thing for a candidate to do twice (a double-click, a refresh, a
    // second thought) and deserves a plain answer, not a 500.
    if (candidateError.code === "23505") {
      return json({ error: "you have already applied to this organization" }, 409);
    }
    // Anything else is ours, not theirs. The raw Postgres message used to
    // go straight back to the browser — column names, constraint names, and
    // table structure handed to an unauthenticated caller.
    console.error(`candidate insert failed for ${organizationId}: ${candidateError.message}`);
    return json({ error: "could not record this application" }, 500);
  }

  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const code = Array.from(
    crypto.getRandomValues(new Uint8Array(6)),
    (b) => alphabet[b % alphabet.length],
  ).join("");

  const oneHourMs = 60 * 60 * 1000;
  const codeSendAt = new Date(scheduledAt.getTime() - oneHourMs);
  const reminderSendAt = new Date(scheduledAt.getTime() - oneHourMs / 2);
  // A code for a scheduled slot is meaningless once that slot has passed —
  // give it a day past the scheduled time as a grace window (a candidate
  // running late, a clock skew) rather than expiring it at the exact
  // instant the interview was supposed to start.
  const expiresAt = new Date(scheduledAt.getTime() + 24 * oneHourMs);

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
    expires_at: expiresAt.toISOString(),
  });
  if (invitationError) {
    // Same reasoning as the candidate insert above, one step later: the
    // résumé AND the candidate row are both already written, and neither
    // is reachable by anything if this application never gets an
    // invitation. Undo both rather than leaving a half-applied candidate
    // sitting in the HR dashboard with no code coming.
    await discardOrphanedResume();
    await client.from("candidates").delete().eq("id", candidateId);
    console.error(`invitation insert failed for ${candidateId}: ${invitationError.message}`);
    return json({ error: "could not record this application" }, 500);
  }

  return json({ ok: true, candidateId, invitationId }, 201);
});
