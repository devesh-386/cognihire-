// Thin client for the CogniHire AI Gateway's /interview/* routes.
//
// This is the only place in the portal that knows the gateway's URL or
// request shapes — mirrors the "thin, dumb client" rule applied to the
// Flutter app: the portal never sees a provider name, a prompt, or the
// candidate's knowledge profile, only the turn the gateway decides to send.

const GATEWAY_URL = process.env.NEXT_PUBLIC_GATEWAY_URL || "http://localhost:8000";

async function post(path, body) {
  const response = await fetch(`${GATEWAY_URL}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
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

export function startInterview({ code }) {
  return post("/interview/start", { code });
}

export function submitAnswer({ sessionId, answerText }) {
  return post("/interview/answer", { session_id: sessionId, answer_text: answerText });
}

export function finishInterview({ sessionId, reason }) {
  return post("/interview/finish", { session_id: sessionId, reason });
}
