// Runs on the audio thread: takes float samples from the mic and posts them
// back as Int16 PCM, the format the Realtime API expects. A static file
// rather than a blob: URL — some browsers/extensions block audioWorklet's
// internal fetch() of blob-URL modules, which surfaced as "Failed to fetch"
// with no WebSocket ever attempted.
class MicCaptureProcessor extends AudioWorkletProcessor {
  process(inputs) {
    const channel = inputs[0]?.[0];
    if (!channel) return true;
    const pcm = new Int16Array(channel.length);
    for (let i = 0; i < channel.length; i++) {
      const clamped = Math.max(-1, Math.min(1, channel[i]));
      pcm[i] = clamped < 0 ? clamped * 0x8000 : clamped * 0x7fff;
    }
    this.port.postMessage(pcm.buffer, [pcm.buffer]);
    return true;
  }
}
registerProcessor('mic-capture', MicCaptureProcessor);
