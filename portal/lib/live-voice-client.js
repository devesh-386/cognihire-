// Thin client for the real-time voice interview channel.
//
// Same boundary `gateway.js` draws for text, drawn here for audio: this
// module knows the WS URL and the audio framing, and nothing else. It has
// no provider name, no API key, no prompt, no question text — the backend
// relay (service/session/live_interview.py) owns all of that, and the
// candidate's browser only ever ships microphone frames and plays back
// whatever audio comes down.
//
// The AI's questions still come from the backend's existing question-plan/
// coverage logic; this is purely how the audio gets in and out.

const GATEWAY_URL = process.env.NEXT_PUBLIC_GATEWAY_URL || "http://localhost:8000";

// Matches session.audio.input/output format.rate in live_interview.py's
// session.update — the Realtime API rejects a mismatched rate outright,
// and resampling in two places would be two places to get it wrong.
const SAMPLE_RATE = 24000;

/** Feature detection for everything this client needs, checked together so
 * the caller gets one honest yes/no rather than failing halfway in. */
export function liveVoiceSupported() {
  if (typeof window === "undefined") return false;
  return (
    typeof WebSocket !== "undefined" &&
    typeof AudioContext !== "undefined" &&
    typeof AudioWorkletNode !== "undefined" &&
    !!navigator.mediaDevices?.getUserMedia
  );
}

// The mic-capture AudioWorkletProcessor lives at /public/mic-capture-worklet.js
// (loaded via addModule below) — not inlined as a blob: URL, because
// audioWorklet.addModule's internal fetch() of a blob: URL is blocked in some
// browsers/extensions, which surfaces as "Failed to fetch" with the
// WebSocket never even attempted.

/**
 * @typedef {{ kind: 'question' | 'followup' | 'complete', topic?: string, question?: string }} LiveVoiceTurn
 * @typedef {{ completion_percent: number }} LiveVoiceCoverage
 */

/**
 * Opens the live voice channel for one interview session.
 *
 * `onTurn`'s shape mirrors interview-flow.tsx's own `Turn`/`Coverage`
 * types exactly (same wire payload — main.py's `/interview/answer` and this
 * WebSocket's `turn` message carry the same turn/coverage JSON) — kept in
 * sync by hand since this file can't import a type from the .tsx that
 * imports it.
 *
 * @param {{
 *   sessionId: string,
 *   code: string,
 *   stream: MediaStream,
 *   onTurn?: (turn: LiveVoiceTurn, coverage: LiveVoiceCoverage | null) => void,
 *   onTranscript?: (text: string) => void,
 *   onComplete?: () => void,
 *   onError?: (error: Error) => void,
 * }} options
 * @returns {Promise<{ stop: () => void }>}
 */
export async function startLiveVoice({
  sessionId, code, stream, onTurn, onTranscript, onComplete, onError,
}) {
  const wsUrl =
    GATEWAY_URL.replace(/^http/, "ws") + `/interview/live/${encodeURIComponent(sessionId)}`;

  const audioContext = new AudioContext({ sampleRate: SAMPLE_RATE });
  await audioContext.audioWorklet.addModule("/mic-capture-worklet.js");

  const ws = new WebSocket(wsUrl);
  ws.binaryType = "arraybuffer";

  // Playback is scheduled rather than fired-and-forgotten: each chunk is
  // queued to start exactly where the previous one ended, otherwise
  // consecutive chunks overlap and the speech garbles. `playheadTime`
  // tracks that boundary; resetting it to `currentTime` on flush is what
  // makes barge-in cut off instantly instead of finishing the sentence.
  let playheadTime = 0;
  const scheduledSources = new Set();

  function playChunk(arrayBuffer) {
    const pcm = new Int16Array(arrayBuffer);
    if (!pcm.length) return;
    const frame = audioContext.createBuffer(1, pcm.length, SAMPLE_RATE);
    const channel = frame.getChannelData(0);
    for (let i = 0; i < pcm.length; i++) {
      channel[i] = pcm[i] / (pcm[i] < 0 ? 0x8000 : 0x7fff);
    }
    const source = audioContext.createBufferSource();
    source.buffer = frame;
    source.connect(audioContext.destination);
    const startAt = Math.max(audioContext.currentTime, playheadTime);
    source.start(startAt);
    playheadTime = startAt + frame.duration;
    scheduledSources.add(source);
    source.onended = () => scheduledSources.delete(source);
  }

  // Barge-in: audio already handed to the AudioContext can't be recalled
  // by the server, so the server tells us to drop it and we stop every
  // scheduled source ourselves. Without this the candidate talks over a
  // question that keeps playing for several more seconds.
  function flushPlayback() {
    for (const source of scheduledSources) {
      try {
        source.stop();
      } catch {
        // Already ended between the cancel and this call — harmless.
      }
    }
    scheduledSources.clear();
    playheadTime = audioContext.currentTime;
  }

  const micSource = audioContext.createMediaStreamSource(stream);
  const capture = new AudioWorkletNode(audioContext, "mic-capture");
  capture.port.onmessage = (event) => {
    if (ws.readyState === WebSocket.OPEN) ws.send(event.data);
  };
  micSource.connect(capture);
  // Not connected to destination on purpose — routing the mic to the
  // speakers would echo the candidate back to themselves and feed that
  // echo straight into the server's VAD.

  ws.onmessage = (event) => {
    if (typeof event.data === "string") {
      let payload;
      try {
        payload = JSON.parse(event.data);
      } catch {
        return;
      }
      if (payload.type === "flush_playback") flushPlayback();
      else if (payload.type === "turn") onTurn?.(payload.turn, payload.coverage ?? null);
      // What the server heard the candidate say. Display only — the same
      // text is already graded server-side, so dropping it here costs the
      // candidate their on-screen echo and nothing else.
      else if (payload.type === "candidate_transcript") onTranscript?.(payload.text);
      else if (payload.type === "interview_complete") onComplete?.();
      return;
    }
    playChunk(event.data);
  };

  ws.onerror = () => onError?.(new Error("the live voice connection failed"));

  await new Promise((resolve, reject) => {
    ws.onopen = () => {
      // The interview code goes in the first message, never the URL —
      // a query param would put it in proxy/access logs.
      ws.send(JSON.stringify({ code }));
      resolve();
    };
    ws.addEventListener("close", () => reject(new Error("the live voice connection closed")), {
      once: true,
    });
  });

  function stop() {
    try {
      capture.port.onmessage = null;
      capture.disconnect();
      micSource.disconnect();
    } catch {
      // Already torn down.
    }
    flushPlayback();
    audioContext.close().catch(() => {});
    if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING) ws.close();
  }

  return { stop };
}
