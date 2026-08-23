/**
 * Regression test for the live-voice connect deadlock.
 *
 * The effect that opens the real-time channel used to list `liveVoice` in
 * its dependency array while setting that same state one line into its
 * body. React tore the effect down and re-ran it mid-connect; the re-run
 * bailed on the `liveVoice !== 'off'` guard, and the in-flight
 * `startLiveVoice` promise resolved into `cancelled` and stopped the socket
 * it had just opened. The UI sat on "Connecting the live conversation…"
 * forever, and because the Web Speech fallback is suppressed in that state,
 * the candidate got no voice at all.
 *
 * The first test below fails against that code and passes against the fix.
 */

import { describe, expect, it, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import { act } from 'react'

// One router object for the whole module: the real `useRouter` returns a
// stable reference, and the live-voice effect depends on it. Handing back a
// fresh object per render would re-fire that effect on every render and
// reproduce the deadlock for a reason the component isn't responsible for.
const routerPush = vi.fn()
const router = { push: routerPush }
vi.mock('next/navigation', () => ({
  useRouter: () => router,
}))

const startInterview = vi.fn()
const recordInterviewEvent = vi.fn(async (..._args: unknown[]) => ({ recorded: true }))

vi.mock('@/lib/gateway', () => ({
  startInterview: (...args: unknown[]) => startInterview(...args),
  submitAnswer: vi.fn(),
  analyzeFace: vi.fn(async () => ({ face_detected: true })),
  recordInterviewEvent: (...args: unknown[]) => recordInterviewEvent(...args),
}))

// Resolves only when the test says so, standing in for the AudioWorklet load
// plus WebSocket open. The deadlock lives in that window, so the test has to
// own when it closes.
let resolveConnect: (handle: { stop: () => void }) => void
const stop = vi.fn()

vi.mock('@/lib/live-voice-client', () => ({
  liveVoiceSupported: () => true,
  startLiveVoice: vi.fn(
    () => new Promise((resolve) => {
      resolveConnect = resolve
    }),
  ),
}))

import { InterviewFlow } from './interview-flow'

async function reachTheFirstQuestion() {
  render(<InterviewFlow code="TESTCODE" />)

  // Device check, then start: the live-voice effect only fires once a
  // session exists and the first question is on screen.
  await act(async () => {
    screen.getByRole('button', { name: /check camera & microphone/i }).click()
  })
  await act(async () => {
    screen.getByRole('button', { name: /enter interview room/i }).click()
  })
}

describe('InterviewFlow live voice', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    startInterview.mockResolvedValue({
      session_id: 'session-1',
      coverage: { completion_percent: 0 },
      turn: { kind: 'question', topic: 'React', question: 'Tell me about a project.' },
    })
  })

  it('goes live once the channel connects, instead of hanging on "Connecting"', async () => {
    await reachTheFirstQuestion()

    expect(screen.getByText(/connecting the live conversation/i)).toBeDefined()

    await act(async () => {
      resolveConnect({ stop })
    })

    await waitFor(() => {
      expect(screen.getByText(/just talk — the interview is listening/i)).toBeDefined()
    })
    // The connect must survive its own state update. Stopping here is the
    // exact failure the old dependency array produced.
    expect(stop).not.toHaveBeenCalled()
    expect(screen.queryByText(/connecting the live conversation/i)).toBeNull()
  })

  it('falls back to the typed path when the channel never connects', async () => {
    await reachTheFirstQuestion()
    expect(screen.getByRole('button', { name: /submit answer/i })).toBeDefined()
    expect(screen.getByPlaceholderText(/type your answer/i)).toBeDefined()
  })
})
