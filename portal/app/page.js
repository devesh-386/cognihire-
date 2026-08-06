"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";

export default function Home() {
  const router = useRouter();
  const [code, setCode] = useState("");

  function begin(e) {
    e.preventDefault();
    const trimmed = code.trim().toUpperCase();
    if (!trimmed) return;
    router.push(`/interview?code=${encodeURIComponent(trimmed)}`);
  }

  return (
    <main style={{ maxWidth: 440, margin: "12vh auto", padding: "0 24px" }}>
      <h1 style={{ fontSize: 28, marginBottom: 4 }}>CogniHire</h1>
      <p style={{ color: "#9aa7b8", marginTop: 0 }}>
        Enter the interview code you were sent to begin.
      </p>

      <form onSubmit={begin} style={{ display: "grid", gap: 12, marginTop: 24 }}>
        <label style={{ display: "grid", gap: 4 }}>
          <span style={{ fontSize: 13, color: "#9aa7b8" }}>Interview code</span>
          <input
            required
            autoFocus
            value={code}
            onChange={(e) => setCode(e.target.value)}
            placeholder="e.g. 7K3PXM2Q"
            style={{ ...inputStyle, letterSpacing: 2, fontSize: 20, textTransform: "uppercase" }}
          />
        </label>
        <button type="submit" style={buttonStyle}>
          Continue
        </button>
      </form>

      <p style={{ fontSize: 12, color: "#4d5b70", marginTop: 24 }}>
        Codes are single-use and expire after a set window. If yours doesn't
        work, contact the person who sent it to you.
      </p>
    </main>
  );
}

const inputStyle = {
  padding: "10px 12px",
  borderRadius: 8,
  border: "1px solid #2a3446",
  background: "#131b2b",
  color: "#e7ecf3",
  fontSize: 15,
};

const buttonStyle = {
  padding: "12px 16px",
  borderRadius: 8,
  border: "none",
  background: "#3b6fe0",
  color: "white",
  fontSize: 15,
  fontWeight: 600,
  cursor: "pointer",
  marginTop: 8,
};
