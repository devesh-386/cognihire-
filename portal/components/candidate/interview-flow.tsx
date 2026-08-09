'use client'

import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { useEffect, useRef, useState } from 'react'
import { Camera, Check, Loader2, Mic, TriangleAlert } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { InterviewCodeForm } from '@/components/candidate/interview-code-form'
import { cn } from '@/lib/utils'
import { startInterview, submitAnswer } from '@/lib/gateway'

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

export function InterviewFlow({ code }: { code?: string }) {
  const router = useRouter()
  const [deviceStatus, setDeviceStatus] = useState<DeviceStatus>('idle')
  const [sessionStatus, setSessionStatus] = useState<SessionStatus>('devices')
  const [message, setMessage] = useState<string | null>(null)
  const [sessionId, setSessionId] = useState<string | null>(null)
  const [turn, setTurn] = useState<Turn | null>(null)
  const [coverage, setCoverage] = useState<Coverage | null>(null)
  const [answerText, setAnswerText] = useState('')
  const videoRef = useRef<HTMLVideoElement>(null)
  const streamRef = useRef<MediaStream | null>(null)

  useEffect(() => {
    return () => {
      streamRef.current?.getTracks().forEach((track) => track.stop())
    }
  }, [])

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
    } catch (error) {
      console.log('[v0] device check failed:', error)
      setDeviceStatus('denied')
      setMessage(
        'We could not access your camera and microphone. Allow permissions in your browser, then try again.',
      )
    }
  }

  async function beginInterview() {
    setSessionStatus('starting')
    setMessage(null)
    try {
      const result = await startInterview({ code })
      setSessionId(result.session_id)
      setCoverage(result.coverage)
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

  async function handleAnswerSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!answerText.trim() || !sessionId) return
    setSessionStatus('submitting')
    try {
      const result = await submitAnswer({
        sessionId,
        answerText: answerText.trim(),
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
    }
  }

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

        <form onSubmit={handleAnswerSubmit} className="mt-8 flex flex-col gap-4">
          <textarea
            value={answerText}
            onChange={(event) => setAnswerText(event.target.value)}
            disabled={submitting}
            rows={6}
            placeholder="Type your answer…"
            className="w-full rounded-xl border border-input bg-background px-4 py-3 text-sm leading-relaxed outline-none transition-colors placeholder:text-muted-foreground focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/25 disabled:opacity-60"
          />
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
