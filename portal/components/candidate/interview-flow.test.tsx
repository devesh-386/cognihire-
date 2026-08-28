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
const submitAnswer = vi.fn()
const recordInterviewEvent = vi.fn(async (..._args: unknown[]) => ({ recorded: true }))

vi.mock('@/lib/gateway', () => ({
  startInterview: (...args: unknown[]) => startInterview(...args),
  submitAnswer: (...args: unknown[]) => submitAnswer(...args),
  analyzeFace: vi.fn(async () => ({ face_detected: true })),
  recordInterviewEvent: (...args: unknown[]) => recordInterviewEvent(...args),
}))

// Resolves only when the test says so, standing in for the AudioWorklet load
// plus WebSocket open. The deadlock lives in that window, so the test has to
// own when it closes.
let resolveConnect: (handle: { stop: () => void }) => void
const stop = vi.fn()

// Flipped per-test: the spoken-fallback suite needs the real-time channel to
// report unavailable so the Web Speech path is the one under test.
let liveVoiceSupportedResult = true

vi.mock('@/lib/live-voice-client', () => ({
  liveVoiceSupported: () => liveVoiceSupportedResult,
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

/**
 * End-of-speech submission.
 *
 * The Web Speech fallback used to transcribe into the textarea and then wait
 * for a click on "Submit answer". Speech has no equivalent of clicking
 * submit — a candidate simply stops talking — so in a real interview the mic
 * read "Listening" indefinitely and answers were never sent. Observed in a
 * live session before this was added.
 */
class FakeRecognition {
  continuous = false
  interimResults = false
  lang = ''
  onresult: ((event: unknown) => void) | null = null
  onerror: (() => void) | null = null
  onend: (() => void) | null = null
  stopped = false
  static latest: FakeRecognition | null = null

  constructor() {
    FakeRecognition.latest = this
  }
  start() {}
  stop() {
    this.stopped = true
  }
}

function speak(text: string) {
  FakeRecognition.latest?.onresult?.({ results: [[{ transcript: text }]] })
}

describe('InterviewFlow spoken answers', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    liveVoiceSupportedResult = false
    FakeRecognition.latest = null
    Object.defineProperty(window, 'SpeechRecognition', {
      value: FakeRecognition,
      configurable: true,
      writable: true,
    })
    // Turning recognition on also turns on the question-reading TTS path,
    // which jsdom has no constructor for.
    Object.defineProperty(window, 'SpeechSynthesisUtterance', {
      value: class {
        constructor(public text: string) {}
      },
      configurable: true,
      writable: true,
    })
    startInterview.mockResolvedValue({
      session_id: 'session-1',
      coverage: { completion_percent: 0 },
      turn: { kind: 'question', topic: 'React', question: 'Tell me about a project.' },
    })
    submitAnswer.mockResolvedValue({
      coverage: { completion_percent: 50 },
      turn: { kind: 'question', topic: 'SQL', question: 'And databases?' },
    })
  })

  async function startTalking() {
    await reachTheFirstQuestion()
    await act(async () => {
      screen.getByRole('button', { name: /start voice input/i }).click()
    })
  }

  it('sends the answer once the candidate stops speaking', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    try {
      await startTalking()
      await act(async () => {
        speak('I built a claim extraction pipeline on top of FastAPI and Postgres.')
      })
      expect(submitAnswer).not.toHaveBeenCalled()

      await act(async () => {
        await vi.advanceTimersByTimeAsync(3000)
      })
      await waitFor(() => expect(submitAnswer).toHaveBeenCalledTimes(1))
      expect(submitAnswer.mock.calls[0][0]).toMatchObject({
        sessionId: 'session-1',
        answerText: 'I built a claim extraction pipeline on top of FastAPI and Postgres.',
      })
    } finally {
      vi.useRealTimers()
    }
  })

  it('extends the pause instead of cutting the candidate off mid-answer', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    try {
      await startTalking()
      await act(async () => {
        speak('I built a claim extraction pipeline')
      })
      await act(async () => {
        await vi.advanceTimersByTimeAsync(2000)
      })
      // Still mid-sentence: a pause shorter than the window must not send.
      expect(submitAnswer).not.toHaveBeenCalled()

      await act(async () => {
        speak('I built a claim extraction pipeline on top of FastAPI and Postgres.')
      })
      await act(async () => {
        await vi.advanceTimersByTimeAsync(2000)
      })
      expect(submitAnswer).not.toHaveBeenCalled()

      await act(async () => {
        await vi.advanceTimersByTimeAsync(1000)
      })
      await waitFor(() => expect(submitAnswer).toHaveBeenCalledTimes(1))
    } finally {
      vi.useRealTimers()
    }
  })

  it('does not send recogniser noise as an answer', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    try {
      await startTalking()
      await act(async () => {
        speak('um')
      })
      await act(async () => {
        await vi.advanceTimersByTimeAsync(6000)
      })
      expect(submitAnswer).not.toHaveBeenCalled()
    } finally {
      vi.useRealTimers()
    }
  })

  it('cancels a pending send when the candidate taps the mic off', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    try {
      await startTalking()
      await act(async () => {
        speak('I built a claim extraction pipeline on top of FastAPI.')
      })
      await act(async () => {
        screen.getByRole('button', { name: /stop voice input/i }).click()
      })
      await act(async () => {
        await vi.advanceTimersByTimeAsync(6000)
      })
      expect(submitAnswer).not.toHaveBeenCalled()
    } finally {
      vi.useRealTimers()
    }
  })
})
