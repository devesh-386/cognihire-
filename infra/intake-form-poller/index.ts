// Polls every active intake's Google Form for new responses and turns each
// one into a candidate via the existing intake-webhook function — reusing
// that function's dedup/insert/trigger-chain instead of duplicating it, so
// a submission here flows through the SAME canonical path the legacy
// Apps-Script-driven form already uses: candidate insert -> resume
// processing trigger -> AI profile -> READY_FOR_INTERVIEW ->
// candidate_ready_for_interview trigger -> POST /internal/candidates/{id}/
// auto-invite -> interview code generated -> invitation email sent
// immediately (session/interview_codes.py + notifications/workflow.py,
// Ticket 21) — not on a delay, and not new code written here.
//
// Chosen per the user's explicit decision (not Pub/Sub, not a per-form Apps
// Script): poll the Forms API on a timer, same pattern as
// infra/reminder-scheduler, scheduled the same way via pg_cron + net.http_post
// (see that function's live cron job for the exact shape to mirror when
// scheduling this one).
//
// UNVERIFIED: the exact JSON shape Google returns for a `dateQuestion`
// (includeTime: true) answer has not been observed against a real
// submission yet — the parsing below is a best-effort guess (ISO-parseable
// text) and may need adjusting once a live response is polled.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const FORMS_API = "https://forms.googleapis.com/v1/forms";
const TOKEN_URL = "https://oauth2.googleapis.com/token";

Deno.serve(async (req: Request) => {
  const expectedSecret = Deno.env.get("SCHEDULER_SECRET");
  const providedSecret = req.headers.get("x-scheduler-secret");
  if (!expectedSecret || providedSecret !== expectedSecret) {
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  const clientId = Deno.env.get("GOOGLE_OAUTH_CLIENT_ID");
  const clientSecret = Deno.env.get("GOOGLE_OAUTH_CLIENT_SECRET");
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const webhookSecret = Deno.env.get("INTAKE_WEBHOOK_SECRET");
  if (!clientId || !clientSecret || !webhookSecret) {
    return new Response(
      JSON.stringify({ error: "GOOGLE_OAUTH_CLIENT_ID/CLIENT_SECRET or INTAKE_WEBHOOK_SECRET not configured" }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }

  const client = createClient(supabaseUrl, serviceRoleKey);

  const { data: intakes, error: intakesError } = await client
    .from("intakes")
    .select("id, organization_id, google_form_id, last_polled_response_at, roles(title)")
    .eq("status", "active")
    .not("google_form_id", "is", null);
  if (intakesError) {
    return new Response(JSON.stringify({ error: intakesError.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  let seen = 0;
  let created = 0;
  const failures: string[] = [];

  for (const intake of intakes ?? []) {
    try {
      const { data: connection } = await client
        .from("google_oauth_connections")
        .select("access_token, refresh_token, token_expires_at")
        .eq("organization_id", intake.organization_id)
        .maybeSingle();
      // Org disconnected its Google account (or never connected) — this
      // intake's form just doesn't get polled, not a failure to report.
      if (!connection) continue;

      let accessToken = connection.access_token as string;
      const expiresAt = new Date(connection.token_expires_at as string).getTime();
      if (expiresAt - Date.now() < 60_000) {
        const refreshRes = await fetch(TOKEN_URL, {
          method: "POST",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: new URLSearchParams({
            refresh_token: connection.refresh_token as string,
            client_id: clientId,
            client_secret: clientSecret,
            grant_type: "refresh_token",
          }),
        });
        if (!refreshRes.ok) {
          failures.push(`${intake.id}: token refresh failed (HTTP ${refreshRes.status})`);
          continue;
        }
        const refreshed = await refreshRes.json();
        accessToken = refreshed.access_token;
        await client
          .from("google_oauth_connections")
          .update({
            access_token: accessToken,
            token_expires_at: new Date(Date.now() + refreshed.expires_in * 1000).toISOString(),
          })
          .eq("organization_id", intake.organization_id);
      }

      const formRes = await fetch(`${FORMS_API}/${intake.google_form_id}`, {
        headers: { Authorization: `Bearer ${accessToken}` },
      });
      if (!formRes.ok) {
        failures.push(`${intake.id}: form fetch failed (HTTP ${formRes.status})`);
        continue;
      }
      const form = await formRes.json();
      const titleByQuestionId: Record<string, string> = {};
      // deno-lint-ignore no-explicit-any
      for (const item of (form.items ?? []) as any[]) {
        const questionId = item.questionItem?.question?.questionId;
        if (questionId) titleByQuestionId[questionId] = item.title ?? "";
      }

      const responsesRes = await fetch(`${FORMS_API}/${intake.google_form_id}/responses`, {
        headers: { Authorization: `Bearer ${accessToken}` },
      });
      if (!responsesRes.ok) {
        failures.push(`${intake.id}: responses fetch failed (HTTP ${responsesRes.status})`);
        continue;
      }
      const responsesBody = await responsesRes.json();
      // deno-lint-ignore no-explicit-any
      const responses = (responsesBody.responses ?? []) as any[];

      const sinceMs = intake.last_polled_response_at
        ? new Date(intake.last_polled_response_at as string).getTime()
        : 0;
      let latestSeenMs = sinceMs;

      for (const response of responses) {
        const submittedMs = new Date(response.lastSubmittedTime).getTime();
        if (submittedMs <= sinceMs) continue;
        seen++;

        const answers: Record<string, string> = {};
        for (const [questionId, answerObj] of Object.entries(response.answers ?? {})) {
          const title = titleByQuestionId[questionId] ?? questionId;
          // deno-lint-ignore no-explicit-any
          const textAnswers = (answerObj as any).textAnswers?.answers?.map((a: any) => a.value) ?? [];
          answers[title] = textAnswers.join(", ");
        }

        const preferredRaw = answers["Preferred interview date & time"];
        const preferredParsed = preferredRaw ? new Date(preferredRaw) : null;
        const preferredTimeIso =
          preferredParsed && !isNaN(preferredParsed.getTime()) ? preferredParsed.toISOString() : undefined;

        const payload = {
          secret: webhookSecret,
          formId: intake.google_form_id,
          name: answers["Full name"],
          email: answers["Email"],
          // intake-webhook requires roleTitle to be present but resolves
          // the real role via formId -> intakes.role_id, not this string —
          // it's already known here from the intake's own role, so the
          // candidate is never asked to type or choose it.
          // deno-lint-ignore no-explicit-any
          roleTitle: (intake.roles as any)?.title ?? "Role",
          phone: answers["Phone number"],
          linkedinUrl: answers["LinkedIn or portfolio URL"],
          yearsExperience: answers["Years of experience"],
          resumeLink: answers["Resume link (Google Drive, Dropbox, or other shareable link)"],
          preferredTimeIso,
        };

        const webhookRes = await fetch(`${supabaseUrl}/functions/v1/intake-webhook`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload),
        });
        if (webhookRes.ok) {
          created++;
        } else {
          const errText = await webhookRes.text();
          failures.push(`${intake.id}:${response.responseId}: ${errText.slice(0, 200)}`);
        }

        if (submittedMs > latestSeenMs) latestSeenMs = submittedMs;
      }

      if (latestSeenMs > sinceMs) {
        await client
          .from("intakes")
          .update({ last_polled_response_at: new Date(latestSeenMs).toISOString() })
          .eq("id", intake.id);
      }
    } catch (err) {
      failures.push(`${intake.id}: ${(err as Error).message}`);
    }
  }

  return new Response(JSON.stringify({ ok: true, seen, created, failures }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
