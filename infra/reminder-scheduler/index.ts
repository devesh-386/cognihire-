// Ticket 12 — polled by pg_cron every 5 minutes (see the
// schedule_reminder_cron migration). Sends the redemption code at
// code_send_at and a plain reminder at reminder_send_at, via Gmail SMTP —
// server-side now, closing the client-side-App-Password risk documented on
// GmailSmtpEmailSender back when sending only happened from the Flutter app.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import nodemailer from "npm:nodemailer@6";

Deno.serve(async (req: Request) => {
  const expectedSecret = Deno.env.get("SCHEDULER_SECRET");
  const providedSecret = req.headers.get("x-scheduler-secret");
  if (!expectedSecret || providedSecret !== expectedSecret) {
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  const client = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const gmailAddress = Deno.env.get("GMAIL_ADDRESS");
  const gmailAppPassword = Deno.env.get("GMAIL_APP_PASSWORD");
  if (!gmailAddress || !gmailAppPassword) {
    return new Response(
      JSON.stringify({ error: "GMAIL_ADDRESS/GMAIL_APP_PASSWORD not configured" }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
  const transport = nodemailer.createTransport({
    service: "gmail",
    auth: { user: gmailAddress, pass: gmailAppPassword },
  });

  const now = new Date().toISOString();
  let codesSent = 0;
  let remindersSent = 0;
  const failures: string[] = [];

  // Codes: scheduled, past code_send_at, not yet sent.
  const { data: dueForCode, error: codeQueryError } = await client
    .from("invitations")
    .select("id, code, scheduled_at, candidates(name, email), roles(title)")
    .eq("status", "scheduled")
    .lte("code_send_at", now)
    .is("code_sent_at", null);
  if (codeQueryError) {
    return new Response(JSON.stringify({ error: codeQueryError.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  for (const row of dueForCode ?? []) {
    // deno-lint-ignore no-explicit-any
    const r = row as any;
    const email = r.candidates?.email;
    if (!email) continue;
    try {
      await transport.sendMail({
        from: gmailAddress,
        to: email,
        subject: `Your CogniHire interview code — ${r.roles?.title ?? "your interview"}`,
        text: `Hi ${r.candidates?.name ?? "there"},\n\n` +
          `Your interview is coming up. Use this code to enter: ${r.code}\n\n` +
          `Scheduled for: ${r.scheduled_at}\n`,
      });
      await client
        .from("invitations")
        .update({ status: "pending", code_sent_at: now })
        .eq("id", r.id);
      codesSent++;
    } catch (error) {
      failures.push(`code:${r.id}:${(error as Error).message}`);
    }
  }

  // Reminders: already sent a code (status pending), past reminder_send_at, not yet reminded.
  const { data: dueForReminder, error: reminderQueryError } = await client
    .from("invitations")
    .select("id, scheduled_at, candidates(name, email), roles(title)")
    .eq("status", "pending")
    .lte("reminder_send_at", now)
    .is("reminder_sent_at", null);
  if (reminderQueryError) {
    return new Response(JSON.stringify({ error: reminderQueryError.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  for (const row of dueForReminder ?? []) {
    // deno-lint-ignore no-explicit-any
    const r = row as any;
    const email = r.candidates?.email;
    if (!email) continue;
    try {
      await transport.sendMail({
        from: gmailAddress,
        to: email,
        subject: `Reminder — your interview is soon`,
        text: `Hi ${r.candidates?.name ?? "there"},\n\n` +
          `Your interview for ${r.roles?.title ?? "the role"} starts soon ` +
          `(${r.scheduled_at}). Use the code from our earlier email to enter.\n`,
      });
      await client
        .from("invitations")
        .update({ reminder_sent_at: now })
        .eq("id", r.id);
      remindersSent++;
    } catch (error) {
      failures.push(`reminder:${r.id}:${(error as Error).message}`);
    }
  }

  return new Response(
    JSON.stringify({ ok: true, codesSent, remindersSent, failures }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
});
