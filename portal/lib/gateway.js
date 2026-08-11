// Thin client for the CogniHire AI Gateway's /interview/* routes.
//
// This is the only place in the portal that knows the gateway's URL or
// request shapes — mirrors the "thin, dumb client" rule applied to the
// Flutter app: the portal never sees a provider name, a prompt, or the
// candidate's knowledge profile, only the turn the gateway decides to send.

const GATEWAY_URL = process.env.NEXT_PUBLIC_GATEWAY_URL || "http://localhost:8000";

async function request(path, { method = "GET", body, auth = false } = {}) {
  const headers = { "Content-Type": "application/json" };
  if (auth) {
    const session = getSession();
    if (!session) throw new Error("not signed in");
    headers.Authorization = `Bearer ${session.accessToken}`;
  }
  const response = await fetch(`${GATEWAY_URL}${path}`, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    // An expired token is the one failure the workspace cannot render its way
    // out of: AppShell's guard only checks that a session *exists*, and a
    // stale one in localStorage passes that check happily. Without this, an
    // access token going stale mid-session leaves every page showing a
    // generic error with no route back to signing in. Clearing the session
    // and bouncing to /login is the only honest recovery — there is no
    // refresh flow on the backend to try first.
    if (response.status === 401 && auth) {
      clearSession();
      if (typeof window !== "undefined") {
        window.location.href = "/login?expired=1";
      }
      throw new Error("your session expired — please sign in again");
    }
    // /interview/start's code errors carry {reason, message}; every other
    // route still sends a plain string — CodeError is the only place two
    // shapes exist, so this is the one call site that has to handle both.
    const detail = data.detail;
    const message =
      typeof detail === "object" && detail !== null ? detail.message : detail;
    const error = new Error(message || `request to ${path} failed: HTTP ${response.status}`);
    error.reason = typeof detail === "object" && detail !== null ? detail.reason : undefined;
    throw error;
  }
  return data;
}

function post(path, body) {
  return request(path, { method: "POST", body });
}

function get(path) {
  return request(path, { auth: true });
}

/// A POST that carries the HR bearer token. Separate from [post] rather than
/// a flag on it so a candidate-facing route can never accidentally be given
/// an org credential: the public routes (/interview/*, /register-interest)
/// call `post`, the workspace ones call this.
function authPost(path, body) {
  return request(path, { method: "POST", body, auth: true });
}

// --- HR session storage ----------------------------------------------------
// No cookie/session infra exists on the backend yet (token is a bare GoTrue
// access token, no refresh flow) — localStorage is the honest reflection of
// that, not a placeholder for something more sophisticated.

const SESSION_KEY = "cognihire_hr_session";

export function getSession() {
  if (typeof window === "undefined") return null;
  try {
    const raw = window.localStorage.getItem(SESSION_KEY);
    return raw ? JSON.parse(raw) : null;
  } catch {
    return null;
  }
}

function setSession(session) {
  if (typeof window === "undefined") return;
  window.localStorage.setItem(SESSION_KEY, JSON.stringify(session));
}

export function clearSession() {
  if (typeof window === "undefined") return;
  window.localStorage.removeItem(SESSION_KEY);
}

export function startInterview({ code }) {
  return post("/interview/start", { code });
}

export function submitAnswer({ sessionId, answerText, code }) {
  return post("/interview/answer", { session_id: sessionId, answer_text: answerText, code });
}

export function finishInterview({ sessionId, code, reason }) {
  return post("/interview/finish", { session_id: sessionId, code, reason });
}

// Records one client-observed signal (face verification result, tab/window/
// fullscreen/connection change) against a session. Never sends a verdict —
// only what was observed; see service/session/events.py's EventType doc.
export function recordInterviewEvent({ sessionId, code, eventType, payload = {} }) {
  return post("/interview/event", {
    session_id: sessionId, code, event_type: eventType, payload,
  });
}

// Multipart upload to /face/analyze — the one gateway call that isn't JSON,
// so it bypasses `request()`/`post()` and talks to fetch directly.
export async function analyzeFace(blob) {
  const form = new FormData();
  form.append("file", blob, "frame.jpg");
  const response = await fetch(`${GATEWAY_URL}/face/analyze`, {
    method: "POST",
    body: form,
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(data?.detail || `face analysis failed: HTTP ${response.status}`);
  }
  return data;
}

// HR-only — reads the same bearer session /roles etc. use.
export function getReport(sessionId) {
  return get(`/interview/report/${sessionId}`);
}

// --- Candidate self-registration --------------------------------------------
// A candidate applies directly from the portal via a role's public link
// (/apply/{roleId}) — no Google Form, no Apps Script webhook. role_id is the
// only thing identifying which org/role the application is for.

export function getRoleApplyInfo(roleId) {
  return request(`/roles/${roleId}/apply-info`);
}

/** Public: every open role, for a candidate with no direct link yet. */
export function listOpenRoles() {
  return request("/roles/open");
}

/**
 * @param {{
 *   roleId: string,
 *   name: string,
 *   email: string,
 *   resumeBase64: string,
 *   preferredTime?: string | null,
 * }} options
 */
export function applyToRole({ roleId, name, email, resumeBase64, preferredTime = null }) {
  return post("/candidates/apply", {
    role_id: roleId,
    name,
    email,
    resume_base64: resumeBase64,
    preferred_time: preferredTime ?? null,
  });
}

// --- HR portal: auth + org-scoped listing ----------------------------------

export async function signup({ organizationName, name, email, password }) {
  const result = await post("/auth/signup", {
    organization_name: organizationName,
    name: name || null,
    email,
    password,
  });
  setSession({
    accessToken: result.access_token,
    organizationId: result.organization_id,
    organizationName: result.organization_name,
    email: result.email,
  });
  return result;
}

export async function login({ email, password }) {
  const result = await post("/auth/login", { email, password });
  setSession({
    accessToken: result.access_token,
    organizationId: result.organization_id,
    email: result.email,
  });
  return result;
}

export function listRoles() {
  return get("/roles");
}

export function listCandidates() {
  return get("/candidates");
}

export function listInterviews() {
  return get("/interviews");
}

export function listReports() {
  return get("/reports");
}

export function listInterviewCodes() {
  return get("/interview-codes");
}

/**
 * Mints an interview code for one candidate and — server-side — emails the
 * invitation. `organization_id` is deliberately absent: the gateway resolves
 * it from the bearer token and refuses a candidate outside it, so there is
 * nothing here for a caller to get wrong or spoof.
 *
 * The annotation below is load-bearing, not decoration, and must stay a
 * `/**` block rather than the `///` lines used elsewhere in this file —
 * TypeScript only reads the block form. `next.config.mjs` sets
 * `typescript.ignoreBuildErrors`, so a wrong call shape from a .tsx caller
 * builds clean and fails at runtime; without this, TS also infers
 * `requiredSkills` as `never[]` from its own default and rejects every real
 * array passed to it.
 *
 * @param {{
 *   candidateId: string,
 *   roleTitle: string,
 *   requiredSkills?: string[],
 *   difficulty?: string,
 *   availableMinutes?: number,
 *   maxAttempts?: number,
 *   expiresInHours?: number,
 *   scheduledAt?: string | null,
 * }} options
 */
export function generateInterviewCode({
  candidateId,
  roleTitle,
  requiredSkills = [],
  difficulty = "standard",
  availableMinutes = 20,
  maxAttempts = 3,
  expiresInHours = 72,
  scheduledAt = null,
}) {
  return authPost("/interview-codes/generate", {
    candidate_id: candidateId,
    role_title: roleTitle,
    required_skills: requiredSkills,
    difficulty,
    available_minutes: availableMinutes,
    max_attempts: maxAttempts,
    expires_in_hours: expiresInHours,
    scheduled_at: scheduledAt,
  });
}
