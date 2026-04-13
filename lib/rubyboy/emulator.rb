# frozen_string_literal: true

module Rubyboy
  class Emulator
    CPU_CLOCK_HZ = 4_194_304
    CYCLE_NANOSEC = 1_000_000_000 / CPU_CLOCK_HZ

    SAVE_STATE_KEYS = [
      SDL::SDL_SCANCODE_1, SDL::SDL_SCANCODE_2, SDL::SDL_SCANCODE_3,
      SDL::SDL_SCANCODE_4, SDL::SDL_SCANCODE_5, SDL::SDL_SCANCODE_6,
      SDL::SDL_SCANCODE_7, SDL::SDL_SCANCODE_8, SDL::SDL_SCANCODE_9,
      SDL::SDL_SCANCODE_0
    ].freeze

    def initialize(rom_path)
      @rom_path = rom_path
      rom_data = File.open(rom_path, 'r') { _1.read.bytes }
      @rom = Rom.new(rom_data)
      @ram = Ram.new
      @mbc = Cartridge::Factory.create(@rom, @ram)
      @interrupt = Interrupt.new
      @ppu = Ppu.new(@interrupt)
      @timer = Timer.new(@interrupt)
      @joypad = Joypad.new(@interrupt)
      @apu = Apu.new
      @bus = Bus.new(@ppu, @rom, @ram, @mbc, @timer, @interrupt, @joypad, @apu)
      @cpu = Cpu.new(@bus, @interrupt)
      @lcd = Lcd.new
      @audio = Audio.new
      @prev_save_state_keys = Array.new(SAVE_STATE_KEYS.size, 0)
    end

    def save_state(slot: nil, path: nil)
      resolved = path || slot_path(slot)
      ok = StateFile.write(resolved, rom: @rom) do |io|
        @cpu.state_dump(io)
        @ppu.state_dump(io)
        @apu.state_dump(io)
        @timer.state_dump(io)
        @interrupt.state_dump(io)
        @joypad.state_dump(io)
        @ram.state_dump(io)
        @mbc.state_dump(io)
      end
      puts "State saved to #{resolved}" if ok
      ok
    end

    def load_state(slot: nil, path: nil)
      resolved = path || slot_path(slot)
      ok = StateFile.read(resolved, rom: @rom) do |io|
        @cpu.state_restore(io)
        @ppu.state_restore(io)
        @apu.state_restore(io)
        @timer.state_restore(io)
        @interrupt.state_restore(io)
        @joypad.state_restore(io)
        @ram.state_restore(io)
        @mbc.state_restore(io)
      end
      puts "State loaded from #{resolved}" if ok
      ok
    end

    def start
      SDL.InitSubSystem(SDL::INIT_KEYBOARD)

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      elapsed_machine_time = 0
      catch(:exit_loop) do
        loop do
          elapsed_real_time = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - start_time
          while elapsed_real_time > elapsed_machine_time
            cycles = @cpu.exec
            @timer.step(cycles)
            @audio.queue(@apu.samples) if @apu.step(cycles)
            if @ppu.step(cycles)
              @lcd.draw(@ppu.buffer)
              key_input_check
              throw :exit_loop if @lcd.window_should_close?
            end

            elapsed_machine_time += cycles * CYCLE_NANOSEC
          end
        end
      end
      @lcd.close_window
    rescue StandardError => e
      puts e.to_s[0, 100]
      raise e
    end

    def bench(frames)
      @lcd.close_window
      frame_count = 0
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      while frame_count < frames
        cycles = @cpu.exec
        @timer.step(cycles)
        if @ppu.step(cycles)
          key_input_check
          frame_count += 1
        end
      end

      Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - start_time
    end

    private

    def key_input_check
      SDL.PumpEvents
      keyboard = SDL.GetKeyboardState(nil)
      keyboard_state = keyboard.read_array_of_uint8(229)

      direction = (keyboard_state[SDL::SDL_SCANCODE_D]) | (keyboard_state[SDL::SDL_SCANCODE_A] << 1) | (keyboard_state[SDL::SDL_SCANCODE_W] << 2) | (keyboard_state[SDL::SDL_SCANCODE_S] << 3)
      action = (keyboard_state[SDL::SDL_SCANCODE_K]) | (keyboard_state[SDL::SDL_SCANCODE_J] << 1) | (keyboard_state[SDL::SDL_SCANCODE_U] << 2) | (keyboard_state[SDL::SDL_SCANCODE_I] << 3)
      @joypad.direction_button(15 - direction)
      @joypad.action_button(15 - action)

      check_state_save_keys(keyboard_state)
    end

    def check_state_save_keys(keyboard_state)
      shift_held = keyboard_state[SDL::SDL_SCANCODE_LSHIFT] != 0
      SAVE_STATE_KEYS.each_with_index do |scancode, slot|
        current = keyboard_state[scancode]
        if current != 0 && @prev_save_state_keys[slot] == 0
          shift_held ? load_state(slot:) : save_state(slot:)
        end
        @prev_save_state_keys[slot] = current
      end
    end

    def slot_path(slot)
      raise ArgumentError, 'slot must be an integer in 0..9' unless slot.is_a?(Integer) && (0..9).include?(slot)

      base = @rom_path.sub(%r{\.[^./]*\z}, '')
      "#{base}.state#{slot}"
    end
  end
end
