# frozen_string_literal: true

module Rubyboy
  class Emulator
    CPU_CLOCK_HZ = 4_194_304
    CYCLE_NANOSEC = 1_000_000_000 / CPU_CLOCK_HZ

    SPEED_KEYS = {
      SDL::SDL_SCANCODE_F1 => 1.0,
      SDL::SDL_SCANCODE_F2 => 2.0,
      SDL::SDL_SCANCODE_F3 => 4.0,
      SDL::SDL_SCANCODE_F4 => 8.0
    }.freeze

    attr_reader :speed

    def self.normalize_speed(speed)
      normalized = Float(speed)
      raise ArgumentError, 'speed must be 1.0 or greater' unless normalized >= 1.0 && normalized.finite?

      normalized
    rescue ArgumentError, TypeError
      raise ArgumentError, 'speed must be 1.0 or greater'
    end

    def initialize(rom_path, speed: 1.0)
      rom_data = File.open(rom_path, 'r') { _1.read.bytes }
      rom = Rom.new(rom_data)
      @ram = Ram.new(rom)
      mbc = Cartridge::Factory.create(rom, @ram)
      interrupt = Interrupt.new
      @ppu = Ppu.new(interrupt)
      @timer = Timer.new(interrupt)
      @joypad = Joypad.new(interrupt)
      @apu = Apu.new
      @bus = Bus.new(@ppu, rom, @ram, mbc, @timer, interrupt, @joypad, @apu)
      @cpu = Cpu.new(@bus, interrupt)
      @lcd = Lcd.new
      @audio = Audio.new
      @prev_speed_keys = Array.new(SPEED_KEYS.size, 0)
      set_speed(speed, announce: false)
      @save_file = rom.battery? ? SaveFile.new(default_save_path(rom_path)) : nil
      load_save_file
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
            samples_ready = @apu.step(cycles)
            @audio.queue(@apu.samples) if samples_ready && @speed <= 1.0
            if @ppu.step(cycles)
              @lcd.draw(@ppu.buffer)
              key_input_check
              throw :exit_loop if @lcd.window_should_close?
            end

            elapsed_machine_time += cycles * @cycle_nanosec
          end
        end
      end
      @lcd.close_window
    rescue StandardError => e
      puts e.to_s[0, 100]
      raise e
    ensure
      save_save_file
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

    def default_save_path(rom_path)
      dir = File.dirname(rom_path)
      base = File.basename(rom_path, '.*')
      File.join(dir, "#{base}.sav")
    end

    def load_save_file
      return unless @save_file

      bytes = @save_file.read(@ram.eram.size)
      return unless bytes

      @ram.eram.replace(bytes)
      puts "Loaded save from #{@save_file.path}"
    end

    def save_save_file
      return unless @save_file

      puts "Saved to #{@save_file.path}" if @save_file.write(@ram.eram)
    end

    def key_input_check
      SDL.PumpEvents
      keyboard = SDL.GetKeyboardState(nil)
      keyboard_state = keyboard.read_array_of_uint8(229)

      direction = (keyboard_state[SDL::SDL_SCANCODE_D]) | (keyboard_state[SDL::SDL_SCANCODE_A] << 1) | (keyboard_state[SDL::SDL_SCANCODE_W] << 2) | (keyboard_state[SDL::SDL_SCANCODE_S] << 3)
      action = (keyboard_state[SDL::SDL_SCANCODE_K]) | (keyboard_state[SDL::SDL_SCANCODE_J] << 1) | (keyboard_state[SDL::SDL_SCANCODE_U] << 2) | (keyboard_state[SDL::SDL_SCANCODE_I] << 3)
      @joypad.direction_button(15 - direction)
      @joypad.action_button(15 - action)

      check_speed_keys(keyboard_state)
    end

    def check_speed_keys(keyboard_state)
      SPEED_KEYS.each_with_index do |(scancode, speed), index|
        current = keyboard_state[scancode]
        set_speed(speed) if current != 0 && @prev_speed_keys[index] == 0
        @prev_speed_keys[index] = current
      end
    end

    def set_speed(speed, announce: true)
      @speed = self.class.normalize_speed(speed)
      @cycle_nanosec = CYCLE_NANOSEC / @speed
      @audio.clear if @speed > 1.0
      @lcd.title = "Ruby Boy (#{format_speed}x)"
      puts "Speed: #{format_speed}x" if announce
    end

    def format_speed
      @speed.to_i == @speed ? @speed.to_i : @speed
    end
  end
end
