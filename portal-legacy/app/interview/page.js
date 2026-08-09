"use client";

import { useSearchParams } from "next/navigation";
import { Suspense, useEffect, useRef, useState } from "react";
import { startInterview, submitAnswer } from "../../lib/gateway";

const CODE_ERROR_COPY = {
  not_found: "That code wasn't recognized. Double-check it and try again.",
  expired: "This interview code has expired.",
  revoked: "This interview code is no longer valid.",
  already_used: "This interview has already been completed.",
  max_attempts_exceeded: "This code has run out of attempts. Contact the person who sent it to you.",
  not_yet_open: "This interview hasn't opened yet — check back at the scheduled time.",
  window_closed: "This interview's scheduled window has closed.",
};

export default function InterviewPage() {
  return (
    <Suspense fallback={<Status text="Loading…" />}>
      <InterviewFlow />
    </Suspense>
  );
}

function InterviewFlow() {
  const params = useSearchParams();
  const code = params.get("code") || "";

  // device-check -> starting -> asking -> submitting -> complete -> error
  const [status, setStatus] = useState(code ? "device-check" : "error");
  const [error, setError] = useState(code ? null : "No interview code in the link.");
  const [sessionId, setSessionId] = useState(null);
  const [turn, setTurn] = useState(null);
  const [coverage, setCoverage] = useState(null);
  const [answerText, setAnswerText] = useState("");

  async function beginInterview() {
    setStatus("starting");
    try {
      const result = await startInterview({ code });
      setSessionId(result.session_id);
      setTurn(result.turn);
      setCoverage(result.coverage);
      setStatus(result.turn.kind === "complete" ? "complete" : "asking");
    } catch (err) {
      setStatus("error");
      setError(CODE_ERROR_COPY[err.reason] || err.message);
    }
  }

  async function handleSubmit(e) {
    e.preventDefault();
    if (!answerText.trim()) return;
    setStatus("submitting");
    try {
      const result = await submitAnswer({ sessionId, answerText: answerText.trim() });
      setTurn(result.turn);
      setCoverage(result.coverage);
      setAnswerText("");
      setStatus(result.turn.kind === "complete" ? "complete" : "asking");
    } catch (err) {
      setStatus("error");
      setError(err.message);
    }
  }

  if (status === "device-check") return <DeviceCheck onReady={beginInterview} />;
  if (status === "starting") return <Status text="Preparing your interview…" />;
  if (status === "error") return <Status text={error} isError />;

  return (
    <main style={{ maxWidth: 640, margin: "6vh auto", padding: "0 24px" }}>
      <header style={{ marginBottom: 24 }}>
        {coverage && <CoverageBar percent={coverage.completion_percent} />}
      </header>

      {status === "complete" ? (
        <CompleteScreen sessionId={sessionId} />
      ) : (
        <>
          <p style={{ fontSize: 12, textTransform: "uppercase", letterSpacing: 0.5, color: "#6f8098" }}>
            {turn.kind === "followup" ? "Follow-up" : "Question"} · {turn.topic}
          </p>
          <h2 style={{ fontSize: 22, lineHeight: 1.4, marginTop: 4 }}>{turn.question}</h2>

          <form onSubmit={handleSubmit} style={{ marginTop: 24 }}>
            <textarea
              value={answerText}
              onChange={(e) => setAnswerText(e.target.value)}
              disabled={status === "submitting"}
              rows={6}
              placeholder="Type your answer…"
              style={{
                width: "100%",
                padding: 12,
                borderRadius: 8,
                border: "1px solid #2a3446",
                background: "#131b2b",
                color: "#e7ecf3",
                fontSize: 15,
                fontFamily: "inherit",
                resize: "vertical",
                boxSizing: "border-box",
              }}
            />
            <button
              type="submit"
              disabled={status === "submitting" || !answerText.trim()}
              style={{
                marginTop: 12,
                padding: "12px 20px",
                borderRadius: 8,
                border: "none",
                background: status === "submitting" ? "#2a3446" : "#3b6fe0",
                color: "white",
                fontSize: 15,
                fontWeight: 600,
                cursor: status === "submitting" ? "default" : "pointer",
              }}
            >
              {status === "submitting" ? "Submitting…" : "Submit answer"}
            </button>
          </form>
        </>
      )}
    </main>
  );
}

// Camera/mic check per the intake flow: confirms the devices work before the
// interview starts, so a candidate doesn't discover a dead microphone three
// questions in. This does NOT perform identity verification — no reference
// photo exists for the portal to check against yet, so it stays out rather
// than faking a check with nothing behind it.
function DeviceCheck({ onReady }) {
  const videoRef = useRef(null);
  const [cameraOk, setCameraOk] = useState(null); // null = checking, true/false = result
  const [micOk, setMicOk] = useState(null);
  const [problem, setProblem] = useState(null);

  useEffect(() => {
    let stream;
    let cancelled = false;

    navigator.mediaDevices
      ?.getUserMedia({ video: true, audio: true })
      .then((s) => {
        if (cancelled) {
          s.getTracks().forEach((t) => t.stop());
          return;
        }
        stream = s;
        if (videoRef.current) videoRef.current.srcObject = s;
        setCameraOk(s.getVideoTracks().length > 0 && s.getVideoTracks()[0].enabled);
        setMicOk(s.getAudioTracks().length > 0 && s.getAudioTracks()[0].enabled);
      })
      .catch((err) => {
        if (cancelled) return;
        setCameraOk(false);
        setMicOk(false);
        setProblem(err.message || "Camera/microphone access was denied.");
      });

    return () => {
      cancelled = true;
      stream?.getTracks().forEach((t) => t.stop());
    };
  }, []);

  const ready = cameraOk && micOk;

  return (
    <main style={{ maxWidth: 480, margin: "8vh auto", padding: "0 24px" }}>
      <h2 style={{ fontSize: 22 }}>Camera & microphone check</h2>
      <p style={{ color: "#9aa7b8", fontSize: 14 }}>
        We need access to your camera and microphone before starting.
      </p>

      <div
        style={{
          aspectRatio: "4 / 3",
          background: "#131b2b",
          borderRadius: 12,
          overflow: "hidden",
          border: "1px solid #2a3446",
          marginTop: 16,
        }}
      >
        <video ref={videoRef} autoPlay muted playsInline style={{ width: "100%", height: "100%", objectFit: "cover" }} />
      </div>

      <div style={{ display: "grid", gap: 6, marginTop: 16, fontSize: 14 }}>
        <CheckRow label="Camera" ok={cameraOk} />
        <CheckRow label="Microphone" ok={micOk} />
      </div>

      {problem && (
        <p style={{ color: "#e0625c", fontSize: 13, marginTop: 12 }}>
          {problem} Check your browser's site permissions and reload.
        </p>
      )}

      <button
        onClick={onReady}
        disabled={!ready}
        style={{
          marginTop: 20,
          padding: "12px 20px",
          borderRadius: 8,
          border: "none",
          background: ready ? "#3b6fe0" : "#2a3446",
          color: "white",
          fontSize: 15,
          fontWeight: 600,
          cursor: ready ? "pointer" : "default",
          width: "100%",
        }}
      >
        {ready ? "Start interview" : "Waiting for camera & microphone…"}
      </button>
    </main>
  );
}

function CheckRow({ label, ok }) {
  const color = ok === null ? "#6f8098" : ok ? "#3fbf7f" : "#e0625c";
  const text = ok === null ? "Checking…" : ok ? "Working" : "Not available";
  return (
    <div style={{ display: "flex", justifyContent: "space-between" }}>
      <span style={{ color: "#9aa7b8" }}>{label}</span>
      <span style={{ color }}>{text}</span>
    </div>
  );
}

function CoverageBar({ percent }) {
  return (
    <div style={{ marginTop: 8 }}>
      <div style={{ height: 6, borderRadius: 3, background: "#1c2536", overflow: "hidden" }}>
        <div
          style={{
            height: "100%",
            width: `${percent}%`,
            background: "#3b6fe0",
            transition: "width 300ms ease",
          }}
        />
      </div>
      <p style={{ fontSize: 12, color: "#6f8098", marginTop: 4 }}>{percent}% covered</p>
    </div>
  );
}

function CompleteScreen({ sessionId }) {
  return (
    <div>
      <h2 style={{ fontSize: 24 }}>Interview complete</h2>
      <p style={{ color: "#9aa7b8" }}>
        Thanks for your time — your responses have been recorded and will be reviewed by the
        hiring team.
      </p>
      <p style={{ fontSize: 12, color: "#4d5b70" }}>Session {sessionId}</p>
    </div>
  );
}

function Status({ text, isError }) {
  return (
    <main style={{ maxWidth: 480, margin: "20vh auto", padding: "0 24px", textAlign: "center" }}>
      <p style={{ color: isError ? "#e0625c" : "#9aa7b8" }}>{text}</p>
    </main>
  );
}
