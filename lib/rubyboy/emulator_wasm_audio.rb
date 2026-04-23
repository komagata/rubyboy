# frozen_string_literal: true

require_relative 'emulator_wasm'

module Rubyboy
  class EmulatorWasmAudio < EmulatorWasm
    def step(direction_key, action_key)
      @joypad.direction_button(direction_key)
      @joypad.action_button(action_key)
      audio_samples = []
      loop do
        cycles = @cpu.exec
        @timer.step(cycles)
        audio_samples.concat(@apu.samples) if @apu.step(cycles)
        return [@ppu.buffer, audio_samples] if @ppu.step(cycles)
      end
    end
  end
end
