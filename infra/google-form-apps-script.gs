/**
 * Ticket 11 — bind this script to the intake Google Form (Extensions >
 * Apps Script), then add an installable "On form submit" trigger pointing
 * at onFormSubmit. Posts each new response to the Supabase intake-webhook
 * Edge Function, which creates the candidate + a scheduled invitation.
 *
 * Form fields expected, by exact title (rename the questions to match, or
 * update the titles below):
 *   "Full name"            — short answer
 *   "Email"                — short answer, validated as email
 *   "Which role are you applying for?" — short answer or dropdown, must
 *                             match a Role.title already created by HR
 *   "Preferred interview time" — date+time question
 *   "Resume"                — file upload, one PDF/DOCX
 */

const WEBHOOK_URL =
  "https://foffzvwmxnsmbixkilxt.supabase.co/functions/v1/intake-webhook";
// Same value as the INTAKE_WEBHOOK_SECRET secret set on the Edge Function —
// see infra/README.md's Ticket 11 section for how to set it.
const WEBHOOK_SECRET = "PASTE_THE_SAME_SECRET_HERE";

function onFormSubmit(e) {
  const responses = e.response.getItemResponses();
  const byTitle = {};
  for (const response of responses) {
    byTitle[response.getItem().getTitle()] = response;
  }

  const name = byTitle["Full name"] ? byTitle["Full name"].getResponse() : null;
  const email = byTitle["Email"] ? byTitle["Email"].getResponse() : null;
  const roleTitle = byTitle["Which role are you applying for?"]
    ? byTitle["Which role are you applying for?"].getResponse()
    : null;
  const preferredTime = byTitle["Preferred interview time"]
    ? byTitle["Preferred interview time"].getResponse()
    : null;

  if (!name || !email || !roleTitle || !preferredTime) {
    console.error("Form response missing a required field — not forwarded.");
    return;
  }

  const payload = {
    secret: WEBHOOK_SECRET,
    name: name,
    email: email,
    roleTitle: roleTitle,
    // Google Forms' date+time answer is already ISO-ish; Date() normalises it.
    preferredTimeIso: new Date(preferredTime).toISOString(),
  };

  const resumeResponse = byTitle["Resume"];
  if (resumeResponse) {
    const fileIds = resumeResponse.getResponse();
    // File-upload questions answer with an array of Drive file IDs.
    if (fileIds && fileIds.length > 0) {
      const file = DriveApp.getFileById(fileIds[0]);
      payload.resumeFilename = file.getName();
      payload.resumeBase64 = Utilities.base64Encode(file.getBlob().getBytes());
    }
  }

  const httpResponse = UrlFetchApp.fetch(WEBHOOK_URL, {
    method: "post",
    contentType: "application/json",
    payload: JSON.stringify(payload),
    muteHttpExceptions: true,
  });

  const code = httpResponse.getResponseCode();
  if (code >= 300) {
    console.error(
      "intake-webhook rejected the submission (" + code + "): " +
        httpResponse.getContentText(),
    );
  }
}
