/**
 * Ticket 11 — bind this script to the intake Google Form (Extensions >
 * Apps Script), then add an installable "On form submit" trigger pointing
 * at onFormSubmit. Posts each new response to the Supabase intake-webhook
 * Edge Function, which creates the candidate + a scheduled invitation.
 *
 * Form fields expected, matched case/whitespace-insensitively (so "FULL
 * NAME" or " Resume " both still match) — rename the questions to something
 * close to these, or update the alias lists below:
 *   "Full name"            — short answer
 *   "Email"                — short answer, validated as email
 *   "Which role are you applying for?" — short answer or dropdown, must
 *                             match a Role.title already created by HR
 *   "Preferred interview time" — date+time question. If the form instead
 *                             splits this into a separate day/date question
 *                             and a time question, both are read and
 *                             combined — see PREFERRED_TIME_ALIASES /
 *                             PREFERRED_DAY_ALIASES below.
 *   "Resume"                — file upload, one PDF/DOCX
 */

const WEBHOOK_URL =
  "https://foffzvwmxnsmbixkilxt.supabase.co/functions/v1/intake-webhook";
// Same value as the INTAKE_WEBHOOK_SECRET secret set on the Edge Function —
// see infra/README.md's Ticket 11 section for how to set it.
const WEBHOOK_SECRET = "PASTE_THE_SAME_SECRET_HERE";

// Every title this module will accept for a given field, normalised (see
// _normalize) before comparison — so "FULL NAME", " Full Name", and "Full
// name" all match the same alias. Add to these lists rather than requiring
// an exact retitle in Forms, which breaks again on the next edit.
const NAME_ALIASES = ["full name", "name"];
const EMAIL_ALIASES = ["email", "email address"];
const ROLE_ALIASES = ["which role are you applying for?", "role"];
const RESUME_ALIASES = ["resume", "résumé", "cv"];
// A single combined date+time question.
const TIME_ALIASES = ["preferred interview time", "preferred time", "interview time"];
// A separate date-only question, combined with TIME_ALIASES's answer if the
// form splits them into two questions instead of one.
const DAY_ALIASES = ["preferred interview day", "preferred date", "interview day"];

// The timezone the candidate answers the form in. Every "preferred interview
// time" answer is interpreted as a wall-clock time in THIS zone and converted
// to UTC explicitly below.
//
// Why this is pinned rather than inherited: `new Date("August 13, 2026 11:45")`
// resolves against the Apps Script PROJECT's timezone (File > Project
// Settings), which is a per-script setting nobody on this project has
// verified, defaults to the creating account's locale, and is silently
// changeable in the UI. If it is not Asia/Kolkata, every interview lands in
// the database shifted by the difference — the candidate says 11:45 and gets a
// 06:15 slot — and nothing downstream can detect it, because a valid-looking
// timestamp is indistinguishable from a correct one. Pinning the offset here
// makes the conversion deterministic regardless of that setting.
//
// A fixed +05:30 is safe: India has never observed daylight saving, so there
// is no transition to get wrong. Change IST_OFFSET_MINUTES only if this
// deployment stops serving IST candidates.
const IST_OFFSET_MINUTES = 330;

function _normalize(title) {
  return (title || "").trim().toLowerCase().replace(/\s+/g, " ");
}

/**
 * Reads the year/month/day/hour/minute the responder actually chose — as
 * rendered in the script's own timezone, which is how Apps Script hands back
 * both a Date-question value and a parsed string — and re-anchors those exact
 * wall-clock numbers to IST, returning a real UTC instant.
 *
 * `local` is only ever used as a carrier of the five field values; its own
 * timezone is deliberately discarded rather than trusted.
 */
function _toUtcFromIst(local) {
  const utcMillis = Date.UTC(
    local.getFullYear(),
    local.getMonth(),
    local.getDate(),
    local.getHours(),
    local.getMinutes(),
    0,
    0,
  );
  return new Date(utcMillis - IST_OFFSET_MINUTES * 60 * 1000);
}

function _findResponse(byNormalizedTitle, aliases) {
  for (const alias of aliases) {
    if (byNormalizedTitle[alias]) return byNormalizedTitle[alias];
  }
  return null;
}

const _WEEKDAYS = [
  "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
];

/**
 * Some forms ask "which day of the week" rather than an actual calendar
 * date (a Multiple Choice/Dropdown answering e.g. "Sunday"), which Date()
 * cannot parse — it has no year or month to anchor to. Resolves that to the
 * next upcoming occurrence of that weekday (today counts as "upcoming" if
 * the time hasn't passed yet), so a real calendar date reaches the webhook
 * either way. Returns null if `dayAnswer` isn't a recognised weekday name,
 * so the caller falls back to parsing it as a literal date string instead.
 */
function _resolveWeekdayToDate(dayAnswer, timeAnswer) {
  const weekdayIndex = _WEEKDAYS.indexOf((dayAnswer || "").trim().toLowerCase());
  if (weekdayIndex === -1) return null;

  const timeParts = /(\d{1,2}):(\d{2})/.exec(timeAnswer || "");
  if (!timeParts) return null;
  const hours = parseInt(timeParts[1], 10);
  const minutes = parseInt(timeParts[2], 10);

  const now = new Date();
  const candidate = new Date(now);
  const daysUntil = (weekdayIndex - now.getDay() + 7) % 7;
  candidate.setDate(now.getDate() + daysUntil);
  candidate.setHours(hours, minutes, 0, 0);

  // If today is the target weekday but that time already passed, this
  // candidate slot is in the past — the intended slot is next week's, not
  // today's, since a form asking "which day" for an interview never means
  // "earlier today".
  if (candidate.getTime() < now.getTime()) {
    candidate.setDate(candidate.getDate() + 7);
  }

  return candidate;
}

function onFormSubmit(e) {
  const responses = e.response.getItemResponses();
  const byNormalizedTitle = {};
  for (const response of responses) {
    byNormalizedTitle[_normalize(response.getItem().getTitle())] = response;
  }

  const nameResponse = _findResponse(byNormalizedTitle, NAME_ALIASES);
  const emailResponse = _findResponse(byNormalizedTitle, EMAIL_ALIASES);
  const roleResponse = _findResponse(byNormalizedTitle, ROLE_ALIASES);
  const timeResponse = _findResponse(byNormalizedTitle, TIME_ALIASES);
  const dayResponse = _findResponse(byNormalizedTitle, DAY_ALIASES);

  const name = nameResponse ? nameResponse.getResponse() : null;
  const email = emailResponse ? emailResponse.getResponse() : null;
  const roleTitle = roleResponse ? roleResponse.getResponse() : null;
  const timeAnswer = timeResponse ? timeResponse.getResponse() : null;
  const dayAnswer = dayResponse ? dayResponse.getResponse() : null;

  if (!name || !email || !roleTitle || !timeAnswer) {
    const missing = [];
    if (!name) missing.push("name");
    if (!email) missing.push("email");
    if (!roleTitle) missing.push("role");
    if (!timeAnswer) missing.push("preferred interview time");
    console.error(
      "Form response missing: " + missing.join(", ") +
        ". Titles actually present on this response: " +
        Object.keys(byNormalizedTitle).join(" | "),
    );
    return;
  }

  // Try resolving a weekday-name day answer ("Sunday") against the time
  // first — Date() cannot parse that on its own. Falls through to a plain
  // concatenated parse for a form whose day question is an actual date.
  let preferredDate = dayAnswer ? _resolveWeekdayToDate(dayAnswer, timeAnswer) : null;
  if (!preferredDate) {
    const combinedTime = dayAnswer ? `${dayAnswer} ${timeAnswer}` : timeAnswer;
    const parsed = new Date(combinedTime);
    if (!isNaN(parsed.getTime())) preferredDate = parsed;
  }
  if (!preferredDate) {
    console.error(
      "Could not parse a valid date from the preferred-time answer(s): " +
        JSON.stringify({ dayAnswer, timeAnswer }),
    );
    return;
  }

  const payload = {
    secret: WEBHOOK_SECRET,
    formId: FormApp.getActiveForm().getId(),
    name: name,
    email: email,
    roleTitle: roleTitle,
    // Re-anchored to IST (see _toUtcFromIst) rather than relying on the Apps
    // Script project's timezone setting to have been correct.
    preferredTimeIso: _toUtcFromIst(preferredDate).toISOString(),
  };

  const resumeResponse = _findResponse(byNormalizedTitle, RESUME_ALIASES);
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
  } else {
    console.log("intake-webhook accepted the submission (" + code + ").");
  }
}
