const RING_CAPACITY = 4096;

class AudioRingProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const { sab } = options.processorOptions;
    this.ctrl = new Int32Array(sab, 0, 4);
    this.data = new Float32Array(sab, 16, RING_CAPACITY * 2);
  }

  process(inputs, outputs) {
    const out = outputs[0];
    const L = out[0];
    const R = out[1];
    const write = Atomics.load(this.ctrl, 0);
    let read = Atomics.load(this.ctrl, 1);
    const available = (write - read + RING_CAPACITY) % RING_CAPACITY;
    const n = L.length;

    for (let i = 0; i < n; i++) {
      if (i < available) {
        L[i] = this.data[read * 2];
        R[i] = this.data[read * 2 + 1];
        read = (read + 1) % RING_CAPACITY;
      } else {
        L[i] = 0;
        R[i] = 0;
      }
    }
    Atomics.store(this.ctrl, 1, read);
    return true;
  }
}

registerProcessor('audio-ring', AudioRingProcessor);
