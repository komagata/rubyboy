const RING_CAPACITY = 4096;
const HEADER_BYTES = 16;

class AudioBridge {
  constructor() {
    this.context = null;
    this.node = null;
    this.sab = null;
    this.ctrl = null;
    this.data = null;
    this.enabled = false;
    this.initPromise = null;
  }

  init() {
    if (this.initPromise) return this.initPromise;
    try {
      this.context = new AudioContext();
    } catch (e) {
      console.error('[audio_bridge] AudioContext creation failed:', e);
      return Promise.resolve(false);
    }
    this.initPromise = this._initAsync();
    return this.initPromise;
  }

  async _initAsync() {
    try {
      if (!self.crossOriginIsolated || typeof SharedArrayBuffer === 'undefined') {
        console.warn('[audio_bridge] SharedArrayBuffer unavailable (crossOriginIsolated=' + self.crossOriginIsolated + '), running silent');
        this.enabled = false;
        return false;
      }

      await this.context.audioWorklet.addModule('./audio-worklet.js');

      const dataBytes = RING_CAPACITY * 2 * 4;
      this.sab = new SharedArrayBuffer(HEADER_BYTES + dataBytes);
      this.ctrl = new Int32Array(this.sab, 0, 4);
      this.data = new Float32Array(this.sab, HEADER_BYTES, RING_CAPACITY * 2);
      Atomics.store(this.ctrl, 0, 0);
      Atomics.store(this.ctrl, 1, 0);
      Atomics.store(this.ctrl, 2, RING_CAPACITY);

      this.node = new AudioWorkletNode(this.context, 'audio-ring', {
        numberOfInputs: 0,
        numberOfOutputs: 1,
        outputChannelCount: [2],
        processorOptions: { sab: this.sab }
      });
      this.node.connect(this.context.destination);
      this.enabled = true;
      console.log('[audio_bridge] initialized, sampleRate=', this.context.sampleRate);
      return true;
    } catch (e) {
      console.error('[audio_bridge] async init failed, running silent:', e);
      this.enabled = false;
      return false;
    }
  }

  writeSamples(samples) {
    if (!this.enabled) return 0;
    const read = Atomics.load(this.ctrl, 1);
    let write = Atomics.load(this.ctrl, 0);
    const free = (read - write - 1 + RING_CAPACITY) % RING_CAPACITY;
    const nFrames = Math.min(Math.floor(samples.length / 2), free);
    for (let i = 0; i < nFrames; i++) {
      this.data[write * 2] = samples[i * 2];
      this.data[write * 2 + 1] = samples[i * 2 + 1];
      write = (write + 1) % RING_CAPACITY;
    }
    Atomics.store(this.ctrl, 0, write);
    return nFrames;
  }

  fillLevel() {
    if (!this.enabled) return 0;
    const read = Atomics.load(this.ctrl, 1);
    const write = Atomics.load(this.ctrl, 0);
    return (write - read + RING_CAPACITY) % RING_CAPACITY;
  }

  fillRatio() {
    return this.fillLevel() / RING_CAPACITY;
  }
}

window.audioBridge = new AudioBridge();

document.addEventListener('visibilitychange', () => {
  const bridge = window.audioBridge;
  if (!bridge || !bridge.context) return;
  if (document.visibilityState === 'visible' && bridge.context.state === 'suspended') {
    bridge.context.resume().catch((e) => {
      console.error('[audio_bridge] resume on visibilitychange failed:', e);
    });
  }
});
