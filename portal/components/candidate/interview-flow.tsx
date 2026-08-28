'use client'

import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { useEffect, useRef, useState } from 'react'
import { Camera, Check, Loader2, Mic, MicOff, TriangleAlert } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { InterviewCodeForm } from '@/components/candidate/interview-code-form'
import { cn } from '@/lib/utils'
import { analyzeFace, recordInterviewEvent, startInterview, submitAnswer } from '@/lib/gateway'
import { liveVoiceSupported, startLiveVoice } from '@/lib/live-voice-client'

// Mirrors portal/app/interview/page.js — /interview/start's code errors are
// the one place the gateway sends a {reason, message} shape instead of a
// plain string, so this map has to live wherever that response is handled.
const CODE_ERROR_COPY: Record<string, string> = {
  not_found: "That code wasn't recognized. Double-check it and try again.",
  expired: 'This interview code has expired.',
  revoked: 'This interview code is no longer valid.',
  already_used: 'This interview has already been completed.',
  max_attempts_exceeded:
    'This code has run out of attempts. Contact the person who sent it to you.',
  not_yet_open:
    "This interview hasn't opened yet — check back at the scheduled time.",
  window_closed: "This interview's scheduled window has closed.",
}

type DeviceStatus = 'idle' | 'checking' | 'ready' | 'denied'
type SessionStatus = 'devices' | 'starting' | 'asking' | 'submitting' | 'error'

type Turn = {
  kind: 'question' | 'followup' | 'complete'
  topic?: string
  question?: string
}
type Coverage = { completion_percent: number }

// How long a candidate may pause before the spoken answer is treated as
// finished. Long enough to think mid-answer — 1.5s cuts people off between
// clauses — short enough that it does not read as the app having hung.
const AUTO_SUBMIT_SILENCE_MS = 3000
// Below this a finalized transcript is recogniser noise rather than an
// answer, so it must not be auto-submitted and spend one of the candidate's
// attempts. Matches the floor live_interview.py applies to the same problem.
const AUTO_SUBMIT_MIN_CHARS = 12

export function InterviewFlow({ code }: { code?: string }) {
  const router = useRouter()
  const [deviceStatus, setDeviceStatus] = useState<DeviceStatus>('idle')
  const [sessionStatus, setSessionStatus] = useState<SessionStatus>('devices')
  const [message, setMessage] = useState<string | null>(null)
  const [sessionId, setSessionId] = useState<string | null>(null)
  const [turn, setTurn] = useState<Turn | null>(null)
  const [coverage, setCoverage] = useState<Coverage | null>(null)
  const [answerText, setAnswerText] = useState('')
  const [listening, setListening] = useState(false)
  const [voiceSupported, setVoiceSupported] = useState(false)
  // 'off' until a session exists; 'live' once the real-time channel is up.
  // 'unavailable' means we tried and it didn't work — the candidate falls
  // back to the Web Speech API / typed path, which never stops working.
  const [liveVoice, setLiveVoice] = useState<'off' | 'connecting' | 'live' | 'unavailable'>('off')
  // WHY the live channel gave up, kept rather than discarded. Every failure
  // path here used to swallow its error and set 'unavailable', so a candidate
  // silently sat through the click-to-talk fallback and nobody — candidate,
  // recruiter, or engineer — could tell whether the real-time channel had
  // never been attempted, been blocked by the browser, or been dropped by the
  // relay. Observed in a real session before this was added. Not shown to the
  // candidate, who can do nothing with it; surfaced in the console so the
  // cause is recoverable after the fact.
  const [liveVoiceError, setLiveVoiceError] = useState<string | null>(null)
  // Mirrors `answerText` for the silence timer below, which fires from a
  // closure created when recognition started and would otherwise submit the
  // empty string it captured then.
  const answerTextRef = useRef('')
  const silenceTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  // Guards the one-in-flight rule across both submit paths: the timer and the
  // button can otherwise fire together and spend two attempts on one answer.
  const submitInFlightRef = useRef(false)
  const videoRef = useRef<HTMLVideoElement>(null)
  const streamRef = useRef<MediaStream | null>(null)
  const recognitionRef = useRef<any>(null)
  const spokenQuestionRef = useRef<string | null>(null)
  const liveVoiceRef = useRef<{ stop: () => void } | null>(null)
  // Captured once devices are ready, before a session exists to attach it
  // to — held here and flushed as an event right after /interview/start
  // returns a session_id. Quality/presence check only: the portal has no
  // enrolment step, so this is not an identity match against a reference
  // face the way the Flutter app's local enrolment flow was.
  const faceCheckRef = useRef<Record<string, unknown> | null>(null)

  useEffect(() => {
    return () => {
      streamRef.current?.getTracks().forEach((track) => track.stop())
    }
  }, [])

  useEffect(() => {
    answerTextRef.current = answerText
  }, [answerText])

  // Records tab/window/fullscreen visibility changes once a session exists.
  // Never a verdict — see service/session/events.py's EventType doc.
  useEffect(() => {
    if (!sessionId) return

    const send = (eventType: string) =>
      recordInterviewEvent({ sessionId, code: code!, eventType }).catch(() => {
        // Best-effort: a dropped behavior signal should never interrupt the
        // interview itself.
      })

    const onVisibility = () => send(document.hidden ? 'tab_hidden' : 'tab_visible')
    const onBlur = () => send('window_blur')
    const onFocus = () => send('window_focus')
    const onFullscreenChange = () => {
      if (!document.fullscreenElement) send('fullscreen_exit')
    }
    const onOnline = () => send('connection_restored')
    const onOffline = () => send('connection_lost')

    document.addEventListener('visibilitychange', onVisibility)
    window.addEventListener('blur', onBlur)
    window.addEventListener('focus', onFocus)
    document.addEventListener('fullscreenchange', onFullscreenChange)
    window.addEventListener('online', onOnline)
    window.addEventListener('offline', onOffline)
    return () => {
      document.removeEventListener('visibilitychange', onVisibility)
      window.removeEventListener('blur', onBlur)
      window.removeEventListener('focus', onFocus)
      document.removeEventListener('fullscreenchange', onFullscreenChange)
      window.removeEventListener('online', onOnline)
      window.removeEventListener('offline', onOffline)
    }
  }, [sessionId, code])

  async function requestDevices() {
    setDeviceStatus('checking')
    setMessage(null)
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        video: true,
        audio: true,
      })
      streamRef.current = stream
      if (videoRef.current) {
        videoRef.current.srcObject = stream
      }
      setDeviceStatus('ready')
      // Give the video element a frame to paint before capturing.
      setTimeout(() => runFaceCheck(), 400)
    } catch (error) {
      console.log('[v0] device check failed:', error)
      setDeviceStatus('denied')
      setMessage(
        'We could not access your camera and microphone. Allow permissions in your browser, then try again.',
      )
    }
  }

  async function runFaceCheck() {
    const video = videoRef.current
    if (!video || !video.videoWidth) return
    const canvas = document.createElement('canvas')
    canvas.width = video.videoWidth
    canvas.height = video.videoHeight
    const ctx = canvas.getContext('2d')
    if (!ctx) return
    ctx.drawImage(video, 0, 0)
    canvas.toBlob(async (blob) => {
      if (!blob) return
      try {
        const analysis = await analyzeFace(blob)
        faceCheckRef.current = {
          face_detected: analysis.face_detected,
          engine_available: analysis.engine_available,
          brightness: analysis.brightness,
          sharpness: analysis.sharpness,
        }
      } catch {
        faceCheckRef.current = { face_detected: false, error: 'analysis_failed' }
      }
    }, 'image/jpeg', 0.85)
  }

  async function beginInterview() {
    setSessionStatus('starting')
    setMessage(null)
    try {
      const result = await startInterview({ code })
      setSessionId(result.session_id)
      setCoverage(result.coverage)
      if (faceCheckRef.current) {
        recordInterviewEvent({
          sessionId: result.session_id,
          code: code!,
          eventType: 'face_verification',
          payload: faceCheckRef.current,
        }).catch(() => {})
      }
      if (result.turn.kind === 'complete') {
        router.push(`/interview/complete?session=${result.session_id}`)
        return
      }
      setTurn(result.turn)
      setSessionStatus('asking')
    } catch (error: any) {
      setSessionStatus('error')
      setMessage(CODE_ERROR_COPY[error?.reason] ?? error?.message ?? 'Something went wrong.')
    }
  }

  function clearSilenceTimer() {
    if (silenceTimerRef.current) {
      clearTimeout(silenceTimerRef.current)
      silenceTimerRef.current = null
    }
  }

  async function handleAnswerSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault()
    await submitCurrentAnswer()
  }

  // Both the Submit button and the end-of-speech timer land here, so the
  // spoken and typed paths cannot diverge in what they send or how they
  // handle failure.
  async function submitCurrentAnswer() {
    const text = answerTextRef.current.trim()
    if (!text || !sessionId || submitInFlightRef.current) return
    submitInFlightRef.current = true
    clearSilenceTimer()
    recognitionRef.current?.stop()
    setSessionStatus('submitting')
    try {
      const result = await submitAnswer({
        sessionId,
        answerText: text,
        code,
      })
      setCoverage(result.coverage)
      setAnswerText('')
      if (result.turn.kind === 'complete') {
        router.push(`/interview/complete?session=${sessionId}`)
        return
      }
      setTurn(result.turn)
      setSessionStatus('asking')
    } catch (error: any) {
      setSessionStatus('error')
      setMessage(error?.message ?? 'Something went wrong.')
    } finally {
      submitInFlightRef.current = false
    }
  }

  // Voice layer around the existing text-turn contract: speaks each question
  // (TTS) and transcribes spoken answers into the same answerText the text
  // box uses (STT) — /interview/start and /interview/answer are untouched,
  // this only changes how the candidate gets text into them. Web Speech API,
  // not a paid provider: free, in-browser, no round-trip latency. Support is
  // inconsistent (good in Chrome/Edge, partial in Safari, absent in
  // Firefox) — the text box always stays as a working fallback, and the UI
  // says so plainly rather than pretending voice always works.
  useEffect(() => {
    const hasRecognition =
      typeof window !== 'undefined' &&
      ('SpeechRecognition' in window || 'webkitSpeechRecognition' in window)
    const hasSynthesis = typeof window !== 'undefined' && 'speechSynthesis' in window
    setVoiceSupported(hasRecognition && hasSynthesis)
  }, [])

  // The real-time conversational channel: continuous listening, natural
  // turn-taking, and barge-in, instead of the click-to-talk Web Speech
  // path above. Strictly an upgrade layer — every failure here (no
  // AudioWorklet, WS blocked, connection dropped) falls back to that path,
  // which itself falls back to typing. The interview is never blocked by
  // this not working.
  //
  // `liveVoice` is deliberately NOT a dependency, and there is no
  // `liveVoice !== 'off'` guard. Both used to be here and together they
  // deadlocked the channel: the effect's own `setLiveVoice('connecting')`
  // changed a value it depended on, so React tore this effect down and
  // re-ran it mid-connect. The re-run hit the guard and returned, and the
  // in-flight `startLiveVoice` promise then resolved into `cancelled`,
  // stopping the socket it had just opened. State never left 'connecting'.
  // What the candidate saw: a question on screen, "Connecting the live
  // conversation…" spinning forever, and silence — the fallback TTS below
  // is suppressed while 'connecting', so the stuck state also swallowed the
  // path this layer is supposed to degrade to. Re-entry is prevented by the
  // dependency list itself now: nothing this effect sets appears in it.
  useEffect(() => {
    if (!sessionId || sessionStatus !== 'asking') return

    // Declared inside the effect so it needs no dependency entry — every
    // caller is within this effect.
    function reportLiveVoiceFailure(detail: string) {
      setLiveVoice('unavailable')
      setLiveVoiceError(detail)
      // eslint-disable-next-line no-console -- the only durable record of why
      // the real-time channel degraded; there is no event type for it and the
      // candidate is not the right audience for the reason.
      console.warn(`[cognihire] live voice unavailable — ${detail}`)
    }

    if (!liveVoiceSupported() || !streamRef.current) {
      reportLiveVoiceFailure(
        !streamRef.current
          ? 'no microphone stream was captured during the device check'
          : 'this browser is missing WebSocket, AudioContext, AudioWorkletNode, or getUserMedia',
      )
      return
    }

    let cancelled = false
    setLiveVoice('connecting')
    startLiveVoice({
      sessionId,
      code: code!,
      stream: streamRef.current,
      onTurn: (nextTurn, nextCoverage) => {
        setTurn(nextTurn)
        if (nextCoverage) setCoverage(nextCoverage)
        // The live channel speaks the question itself — stop the Web
        // Speech TTS effect below from saying it a second time.
        spokenQuestionRef.current = nextTurn.question ?? null
      },
      onComplete: () => router.push(`/interview/complete?session=${sessionId}`),
      onError: (error) => {
        if (!cancelled) reportLiveVoiceFailure(error?.message ?? 'the live voice connection failed')
      },
    })
      .then((handle) => {
        if (cancelled) {
          handle.stop()
          return
        }
        liveVoiceRef.current = handle
        setLiveVoice('live')
      })
      .catch((error: unknown) => {
        // The name matters as much as the message: NotSupportedError from
        // `new AudioContext({sampleRate: 24000})` (hardware that won't run at
        // 24 kHz) and a blocked `addModule` fetch both surface here, and they
        // are different bugs with different fixes.
        if (cancelled) return
        const detail =
          error instanceof Error ? `${error.name}: ${error.message}` : String(error)
        reportLiveVoiceFailure(detail)
      })

    return () => {
      cancelled = true
      liveVoiceRef.current?.stop()
      liveVoiceRef.current = null
    }
  }, [sessionId, sessionStatus, code, router])

  // Speaks each new question/follow-up exactly once — guarded by the
  // question text itself so React StrictMode's double-invoke and answer
  // re-renders don't repeat it.
  useEffect(() => {
    if (!voiceSupported) return
    // The live channel does its own speaking — this local TTS is only for
    // the fallback path, or it would say every question twice at once.
    if (liveVoice === 'live' || liveVoice === 'connecting') return
    if (sessionStatus !== 'asking') return
    if (!turn?.question || turn.question === spokenQuestionRef.current) return
    spokenQuestionRef.current = turn.question
    window.speechSynthesis.cancel()
    window.speechSynthesis.speak(new SpeechSynthesisUtterance(turn.question))
  }, [turn, sessionStatus, voiceSupported, liveVoice])

  function toggleListening() {
    if (!voiceSupported) return
    if (listening) {
      // Tapping the mic off is an explicit "I'm not done" — it must not leave
      // a timer armed that submits three seconds later.
      clearSilenceTimer()
      recognitionRef.current?.stop()
      return
    }
    const SpeechRecognitionCtor =
      (window as any).SpeechRecognition || (window as any).webkitSpeechRecognition
    const recognition = new SpeechRecognitionCtor()
    recognition.continuous = true
    recognition.interimResults = true
    recognition.lang = 'en-US'
    recognition.onresult = (event: any) => {
      let transcript = ''
      for (let i = 0; i < event.results.length; i++) {
        transcript += event.results[i][0].transcript
      }
      setAnswerText(transcript)
      answerTextRef.current = transcript

      // Speech has no equivalent of clicking "submit" — the candidate simply
      // stops talking. Without this the mic said "Listening" forever and the
      // answer was never sent unless the candidate noticed the button, which
      // is not what "just answer the question" looks like to anyone.
      //
      // Armed only once there is enough text to be an answer rather than a
      // stray "um" finalized by the recogniser, and re-armed on every result
      // so a pause mid-sentence extends the window instead of cutting the
      // candidate off. `_MIN` mirrors live_interview.py's own floor for the
      // same reason: below it, a transcript is noise, not an answer.
      clearSilenceTimer()
      if (transcript.trim().length >= AUTO_SUBMIT_MIN_CHARS) {
        silenceTimerRef.current = setTimeout(() => {
          void submitCurrentAnswer()
        }, AUTO_SUBMIT_SILENCE_MS)
      }
    }
    recognition.onerror = () => {
      clearSilenceTimer()
      setListening(false)
    }
    recognition.onend = () => setListening(false)
    recognitionRef.current = recognition
    recognition.start()
    setListening(true)
  }

  useEffect(() => {
    return () => {
      recognitionRef.current?.stop()
      if (silenceTimerRef.current) clearTimeout(silenceTimerRef.current)
      window.speechSynthesis?.cancel()
    }
  }, [])

  if (!code) {
    return (
      <div>
        <p className="label-mono text-muted-foreground">Step 1 of 3</p>
        <h1 className="mt-5 text-3xl leading-[1.1] font-medium tracking-[-0.03em] sm:text-4xl">
          Have an interview code?
        </h1>
        <p className="mt-4 max-w-lg text-sm leading-relaxed text-muted-foreground">
          Enter the code from your invitation. You can complete the interview in
          this browser — we&apos;ll check your camera and microphone first.
        </p>
        <InterviewCodeForm className="mt-8" autoFocus />
      </div>
    )
  }

  if (sessionStatus === 'error') {
    return (
      <div>
        <p className="label-mono text-muted-foreground">
          Interview code
          <span className="ml-2 rounded-md border border-border bg-muted px-2 py-0.5 font-mono text-xs tracking-[0.12em] text-foreground">
            {code}
          </span>
        </p>
        <h1 className="mt-5 text-3xl leading-[1.1] font-medium tracking-[-0.03em] sm:text-4xl">
          We couldn&apos;t start this interview.
        </h1>
        <p
          role="alert"
          className="mt-6 flex gap-2.5 rounded-lg border border-border bg-muted px-4 py-3 text-xs leading-relaxed text-muted-foreground"
        >
          <TriangleAlert aria-hidden="true" className="mt-px size-4 shrink-0" />
          <span>{message}</span>
        </p>
        <Link
          href="/interview"
          className="mt-6 inline-block text-sm text-muted-foreground underline-offset-4 hover:text-foreground hover:underline"
        >
          Use a different code
        </Link>
      </div>
    )
  }

  if (sessionStatus === 'asking' || sessionStatus === 'submitting') {
    const submitting = sessionStatus === 'submitting'
    return (
      <div>
        <p className="label-mono text-muted-foreground">
          {turn?.kind === 'followup' ? 'Follow-up' : 'Question'}
          {turn?.topic ? ` · ${turn.topic}` : null}
        </p>
        <h1 className="mt-5 text-3xl leading-[1.1] font-medium tracking-[-0.03em] sm:text-4xl">
          {turn?.question}
        </h1>

        {coverage ? (
          <div className="mt-8">
            <div className="h-1.5 overflow-hidden rounded-full bg-muted">
              <div
                className="h-full rounded-full bg-primary transition-all duration-300"
                style={{ width: `${coverage.completion_percent}%` }}
              />
            </div>
            <p className="mt-2 text-xs text-muted-foreground">
              {coverage.completion_percent}% covered
            </p>
          </div>
        ) : null}

        {liveVoice === 'live' ? (
          <p className="mt-6 flex items-center gap-2 text-xs text-muted-foreground">
            <span className="relative flex size-2">
              <span className="absolute inline-flex size-full animate-ping rounded-full bg-primary opacity-75" />
              <span className="relative inline-flex size-2 rounded-full bg-primary" />
            </span>
            Just talk — the interview is listening. You can interrupt at any time.
          </p>
        ) : liveVoice === 'connecting' ? (
          <p className="mt-6 flex items-center gap-2 text-xs text-muted-foreground">
            <Loader2 aria-hidden="true" className="size-3.5 animate-spin" />
            Connecting the live conversation…
          </p>
        ) : voiceSupported ? (
          // `data-live-voice-error` carries why the real-time channel degraded
          // so it can be read straight off the DOM in devtools during a
          // support call, without putting a diagnostic in front of a candidate
          // mid-interview. Absent entirely when the channel never failed.
          <p
            className="mt-6 flex items-center gap-2 text-xs text-muted-foreground"
            data-live-voice-error={liveVoiceError ?? undefined}
          >
            {listening
              ? 'Listening — pause when you’re done and your answer sends itself.'
              : 'Speak your answer, or type it below.'}
          </p>
        ) : (
          <p className="mt-6 text-xs text-muted-foreground">
            Voice isn&apos;t supported in this browser — type your answer below.
          </p>
        )}

        <form onSubmit={handleAnswerSubmit} className="mt-3 flex flex-col gap-4">
          <div className="relative">
            <textarea
              value={answerText}
              onChange={(event) => setAnswerText(event.target.value)}
              disabled={submitting}
              rows={6}
              placeholder="Type your answer…"
              className="w-full rounded-xl border border-input bg-background px-4 py-3 pr-14 text-sm leading-relaxed outline-none transition-colors placeholder:text-muted-foreground focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/25 disabled:opacity-60"
            />
            {voiceSupported ? (
              <button
                type="button"
                onClick={toggleListening}
                disabled={submitting}
                aria-label={listening ? 'Stop voice input' : 'Start voice input'}
                className={cn(
                  'absolute right-3 top-3 flex size-9 items-center justify-center rounded-full border transition-colors',
                  listening
                    ? 'border-primary bg-primary text-primary-foreground'
                    : 'border-border bg-background text-muted-foreground hover:text-foreground',
                )}
              >
                {listening ? <MicOff aria-hidden="true" className="size-4" /> : <Mic aria-hidden="true" className="size-4" />}
              </button>
            ) : null}
          </div>
          <Button
            type="submit"
            disabled={submitting || !answerText.trim()}
            className="h-11 self-start rounded-full px-6 text-sm"
          >
            {submitting ? (
              <>
                <Loader2 aria-hidden="true" className="size-4 animate-spin" />
                Submitting…
              </>
            ) : (
              'Submit answer'
            )}
          </Button>
        </form>
      </div>
    )
  }

  // sessionStatus is 'devices' or 'starting' — device check, then hand off to beginInterview
  return (
    <div>
      <p className="label-mono text-muted-foreground">
        Step {deviceStatus === 'ready' ? '3' : '2'} of 3
      </p>
      <h1 className="mt-5 text-3xl leading-[1.1] font-medium tracking-[-0.03em] sm:text-4xl">
        {deviceStatus === 'ready' ? 'You’re set up.' : 'Check your devices.'}
      </h1>
      <p className="mt-4 flex flex-wrap items-center gap-2 text-sm text-muted-foreground">
        Interview code
        <span className="rounded-md border border-border bg-muted px-2 py-0.5 font-mono text-xs tracking-[0.12em] text-foreground">
          {code}
        </span>
      </p>

      <div className="mt-8 grid gap-6 sm:grid-cols-[1fr_0.9fr] sm:items-start">
        <div className="overflow-hidden rounded-xl border border-border bg-ink">
          <div className="relative aspect-4/3">
            <video
              ref={videoRef}
              autoPlay
              playsInline
              muted
              className={cn(
                'size-full object-cover',
                deviceStatus === 'ready' ? 'opacity-100' : 'opacity-0',
              )}
            />
            {deviceStatus !== 'ready' ? (
              <div className="absolute inset-0 flex flex-col items-center justify-center gap-3 text-ink-foreground/60">
                {deviceStatus === 'checking' ? (
                  <Loader2 aria-hidden="true" className="size-5 animate-spin" />
                ) : (
                  <Camera aria-hidden="true" className="size-5" />
                )}
                <span className="label-mono">
                  {deviceStatus === 'checking' ? 'Requesting access' : 'Camera off'}
                </span>
              </div>
            ) : null}
          </div>
        </div>

        <div className="flex flex-col gap-4">
          <ul className="flex flex-col gap-px overflow-hidden rounded-xl border border-border bg-border">
            <DeviceRow
              icon={Camera}
              label="Camera"
              ok={deviceStatus === 'ready'}
              failed={deviceStatus === 'denied'}
            />
            <DeviceRow
              icon={Mic}
              label="Microphone"
              ok={deviceStatus === 'ready'}
              failed={deviceStatus === 'denied'}
            />
          </ul>

          {deviceStatus !== 'ready' ? (
            <Button
              onClick={requestDevices}
              disabled={deviceStatus === 'checking'}
              className="h-11 rounded-full text-sm"
            >
              {deviceStatus === 'checking'
                ? 'Requesting permissions…'
                : 'Check camera & microphone'}
            </Button>
          ) : (
            <Button
              onClick={beginInterview}
              disabled={sessionStatus === 'starting'}
              className="h-11 rounded-full text-sm"
            >
              {sessionStatus === 'starting' ? (
                <>
                  <Loader2 aria-hidden="true" className="size-4 animate-spin" />
                  Preparing your interview…
                </>
              ) : (
                'Enter interview room'
              )}
            </Button>
          )}

          {message ? (
            <p
              role="alert"
              className="flex gap-2.5 rounded-lg border border-border bg-muted px-4 py-3 text-xs leading-relaxed text-muted-foreground"
            >
              <TriangleAlert aria-hidden="true" className="mt-px size-4 shrink-0" />
              <span>{message}</span>
            </p>
          ) : null}
        </div>
      </div>

      <div className="mt-10 flex flex-wrap items-center gap-x-6 gap-y-2 border-t border-border pt-6">
        <Link
          href="/interview"
          className="text-sm text-muted-foreground underline-offset-4 hover:text-foreground hover:underline"
        >
          Use a different code
        </Link>
        <Link
          href="/interview/complete"
          className="text-sm text-muted-foreground underline-offset-4 hover:text-foreground hover:underline"
        >
          Already finished? View confirmation
        </Link>
      </div>
    </div>
  )
}

function DeviceRow({
  icon: Icon,
  label,
  ok,
  failed,
}: {
  icon: typeof Camera
  label: string
  ok: boolean
  failed: boolean
}) {
  return (
    <li className="flex items-center justify-between gap-4 bg-card px-5 py-4">
      <span className="flex items-center gap-3 text-sm">
        <Icon aria-hidden="true" className="size-4 text-muted-foreground" />
        {label}
      </span>
      <span
        className={cn(
          'label-mono flex items-center gap-1.5',
          ok
            ? 'text-accent-foreground'
            : failed
              ? 'text-destructive'
              : 'text-muted-foreground',
        )}
      >
        {ok ? <Check aria-hidden="true" className="size-3.5" /> : null}
        {ok ? 'Ready' : failed ? 'Blocked' : 'Not checked'}
      </span>
    </li>
  )
}
