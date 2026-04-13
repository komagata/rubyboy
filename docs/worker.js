import { DefaultRubyVM } from 'https://cdn.jsdelivr.net/npm/@ruby/wasm-wasi@2.7.1/dist/browser/+esm';
import { File } from 'https://cdn.jsdelivr.net/npm/@bjorn3/browser_wasi_shim@0.3.0/+esm';

const DIRECTION_KEY_MASKS = {
  'KeyD': 0b0001, // Right
  'KeyA': 0b0010, // Left
  'KeyW': 0b0100, // Up
  'KeyS': 0b1000  // Down
};

const ACTION_KEY_MASKS = {
  'KeyK': 0b0001, // A
  'KeyJ': 0b0010, // B
  'KeyU': 0b0100, // Select
  'KeyI': 0b1000  // Start
};

class Rubyboy {
  constructor() {
    this.wasmUrl = 'https://proxy.sacckey.dev/rubyboy.wasm';

    this.directionKey = 0b1111;
    this.actionKey = 0b1111;
  }

  async init() {
    let response = await fetch('./rubyboy.wasm');
    if (!response.ok) {
      response = await fetch(this.wasmUrl);
    }

    const module = await WebAssembly.compileStreaming(response)
    const { vm, wasi } = await DefaultRubyVM(module);
    vm.eval(`
      require 'js'
      require_relative 'lib/executor_audio'

      $executor = ExecutorAudio.new
    `);

    this.vm = vm;
    this.rootDir = wasi.fds[3].dir
  }

  sendPixelData() {
    this.vm.eval(`$executor.exec(${this.directionKey}, ${this.actionKey})`);

    const videoFile = this.rootDir.contents.get('video.data');
    const videoBytes = videoFile.data;
    const transfers = [videoBytes.buffer];

    let audioBytes = null;
    const audioFile = this.rootDir.contents.get('audio.data');
    if (audioFile && audioFile.data.byteLength > 0) {
      audioBytes = audioFile.data;
      transfers.push(audioBytes.buffer);
    }

    postMessage(
      { type: 'frame', video: videoBytes.buffer, audio: audioBytes ? audioBytes.buffer : null },
      transfers
    );
  }

  tick() {
    this.sendPixelData();
  }
}

const rubyboy = new Rubyboy();

self.addEventListener('message', async (event) => {
  if (event.data.type === 'initRubyboy') {
    try {
      await rubyboy.init();
      postMessage({ type: 'initialized', message: 'ok' });
    } catch (error) {
      postMessage({ type: 'error', message: error.message });
    }
  }

  if (event.data.type === 'tick') {
    try {
      rubyboy.tick();
    } catch (error) {
      postMessage({ type: 'error', message: error.message });
    }
  }

  if (event.data.type === 'keydown' || event.data.type === 'keyup') {
    const code = event.data.code;
    const directionKeyMask = DIRECTION_KEY_MASKS[code];
    const actionKeyMask = ACTION_KEY_MASKS[code];

    if (directionKeyMask) {
      if (event.data.type === 'keydown') {
        rubyboy.directionKey &= ~directionKeyMask;
      } else {
        rubyboy.directionKey |= directionKeyMask;
      }
    }

    if (actionKeyMask) {
      if (event.data.type === 'keydown') {
        rubyboy.actionKey &= ~actionKeyMask;
      } else {
        rubyboy.actionKey |= actionKeyMask;
      }
    }
  }

  if (event.data.type === 'loadROM') {
    const romFile = new File(new Uint8Array(event.data.data));
    rubyboy.rootDir.contents.set('rom.data', romFile);
    rubyboy.vm.eval(`
      $executor.read_rom_from_virtual_fs
    `);
  }

  if (event.data.type === 'loadPreInstalledRom') {
    rubyboy.vm.eval(`
      $executor.read_pre_installed_rom("${event.data.romName}")
    `);
  }
});
