# frozen_string_literal: true

require 'js'
require 'json'

require_relative 'rubyboy/emulator_wasm_audio'

class ExecutorAudio
  ALLOWED_ROMS = ['tobu.gb', 'bgbtest.gb'].freeze

  def initialize
    rom_data = File.open('lib/roms/tobu.gb', 'r') { _1.read.bytes }
    @emulator = Rubyboy::EmulatorWasmAudio.new(rom_data)
  end

  def exec(direction_key = 0b1111, action_key = 0b1111)
    video_buffer, audio_samples = @emulator.step(direction_key, action_key)
    File.binwrite('/video.data', video_buffer.pack('V*'))
    File.binwrite('/audio.data', audio_samples.pack('e*'))
  end

  def read_rom_from_virtual_fs
    rom_path = '/rom.data'
    raise "ROM file not found in virtual filesystem at #{rom_path}" unless File.exist?(rom_path)

    rom_data = File.open(rom_path, 'rb') { |file| file.read.bytes }
    @emulator = Rubyboy::EmulatorWasmAudio.new(rom_data)
  end

  def read_pre_installed_rom(rom_name)
    raise 'ROM not found in allowed ROMs' unless ALLOWED_ROMS.include?(rom_name)

    rom_path = File.join('lib/roms', rom_name)
    rom_data = File.open(rom_path, 'r') { _1.read.bytes }
    @emulator = Rubyboy::EmulatorWasmAudio.new(rom_data)
  end
end
