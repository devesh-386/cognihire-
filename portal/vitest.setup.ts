import { afterEach } from 'vitest'
import { cleanup } from '@testing-library/react'

// jsdom has no media stack. Components under test only ever hold the
// MediaStream and hand it to the live-voice client (mocked in tests), so a
// stub with the one method the teardown path calls is enough.
class FakeMediaStream {
  getTracks() {
    return [{ stop: () => {} }]
  }
}

if (!('mediaDevices' in navigator)) {
  Object.defineProperty(navigator, 'mediaDevices', {
    value: { getUserMedia: async () => new FakeMediaStream() },
    configurable: true,
  })
}

// Web Speech is feature-detected, not polyfilled: leaving these undefined
// keeps `voiceSupported` false, which is what a real browser without them
// reports. Tests that need the fallback path define them explicitly.
if (!('speechSynthesis' in window)) {
  Object.defineProperty(window, 'speechSynthesis', {
    value: { speak: () => {}, cancel: () => {} },
    configurable: true,
  })
}

afterEach(() => cleanup())
