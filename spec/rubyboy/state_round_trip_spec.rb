# frozen_string_literal: true

require 'stringio'

# Round-trip checks: dump each runtime class to a StringIO buffer,
# restore a fresh instance from the buffer, and assert that every
# instance variable matches.
RSpec.describe 'state round trip' do
  def round_trip(obj)
    io = StringIO.new
    io.set_encoding(Encoding::ASCII_8BIT)
    obj.state_dump(io)
    io.rewind
    yield(io)
    expect(io.read).to be_nil_or_empty
  end

  RSpec::Matchers.define :be_nil_or_empty do
    match { |actual| actual.nil? || actual.empty? }
  end

  def expect_ivars_match(obj_a, obj_b, ivars)
    ivars.each do |name|
      a = obj_a.instance_variable_get(name)
      b = obj_b.instance_variable_get(name)
      expect(b).to eq(a), "expected #{name} to round-trip; #{a.inspect} != #{b.inspect}"
    end
  end

  describe Rubyboy::Registers do
    it 'round-trips all 8 registers' do
      original = described_class.new
      original.instance_variable_set(:@a, 0x12)
      original.instance_variable_set(:@b, 0x34)
      original.instance_variable_set(:@c, 0x56)
      original.instance_variable_set(:@d, 0x78)
      original.instance_variable_set(:@e, 0x9a)
      original.instance_variable_set(:@f, 0xbc)
      original.instance_variable_set(:@h, 0xde)
      original.instance_variable_set(:@l, 0xf0)

      restored = described_class.new
      round_trip(original) { |io| restored.state_restore(io) }
      expect_ivars_match(original, restored, %i[@a @b @c @d @e @f @h @l])
    end
  end

  describe Rubyboy::Cpu do
    it 'round-trips registers + pc/sp + flags' do
      bus = Object.new
      interrupt = Rubyboy::Interrupt.new
      original = described_class.new(bus, interrupt)
      original.instance_variable_set(:@pc, 0xc0de)
      original.instance_variable_set(:@sp, 0xfeed)
      original.instance_variable_set(:@ime, true)
      original.instance_variable_set(:@ime_delay, true)
      original.instance_variable_set(:@halted, true)

      restored = described_class.new(bus, interrupt)
      round_trip(original) { |io| restored.state_restore(io) }
      expect_ivars_match(original, restored, %i[@pc @sp @ime @ime_delay @halted])
    end
  end

  describe Rubyboy::Timer do
    it 'round-trips DIV/TIMA/TMA/TAC and cycles' do
      interrupt = Rubyboy::Interrupt.new
      original = described_class.new(interrupt)
      original.instance_variable_set(:@div, 0xabcd)
      original.instance_variable_set(:@tima, 0x42)
      original.instance_variable_set(:@tma, 0x99)
      original.instance_variable_set(:@tac, 0x05)
      original.instance_variable_set(:@cycles, 0x1234)

      restored = described_class.new(interrupt)
      round_trip(original) { |io| restored.state_restore(io) }
      expect_ivars_match(original, restored, %i[@div @tima @tma @tac @cycles])
    end
  end

  describe Rubyboy::Interrupt do
    it 'round-trips IE/IF' do
      original = described_class.new
      original.instance_variable_set(:@ie, 0x1f)
      original.instance_variable_set(:@if, 0x0a)

      restored = described_class.new
      round_trip(original) { |io| restored.state_restore(io) }
      expect_ivars_match(original, restored, %i[@ie @if])
    end
  end

  describe Rubyboy::Joypad do
    it 'round-trips mode/action/direction' do
      interrupt = Rubyboy::Interrupt.new
      original = described_class.new(interrupt)
      original.instance_variable_set(:@mode, 0x10)
      original.instance_variable_set(:@action, 0xfd)
      original.instance_variable_set(:@direction, 0xfb)

      restored = described_class.new(interrupt)
      round_trip(original) { |io| restored.state_restore(io) }
      expect_ivars_match(original, restored, %i[@mode @action @direction])
    end
  end

  describe Rubyboy::Ram do
    it 'round-trips all four RAM regions' do
      original = described_class.new
      original.eram[0..3] = [0xde, 0xad, 0xbe, 0xef]
      original.wram1[0..3] = [0x01, 0x02, 0x03, 0x04]
      original.wram2[0..3] = [0x10, 0x20, 0x30, 0x40]
      original.hram[0..3] = [0xff, 0x7f, 0x3f, 0x1f]

      restored = described_class.new
      round_trip(original) { |io| restored.state_restore(io) }
      expect(restored.eram).to eq(original.eram)
      expect(restored.wram1).to eq(original.wram1)
      expect(restored.wram2).to eq(original.wram2)
      expect(restored.hram).to eq(original.hram)
    end
  end

  describe Rubyboy::Cartridge::Mbc1 do
    it 'round-trips banking state' do
      rom = Object.new
      ram = Rubyboy::Ram.new
      original = described_class.new(rom, ram)
      original.instance_variable_set(:@rom_bank, 0x1f)
      original.instance_variable_set(:@ram_bank, 0x03)
      original.instance_variable_set(:@ram_enable, true)
      original.instance_variable_set(:@ram_banking_mode, true)

      restored = described_class.new(rom, ram)
      round_trip(original) { |io| restored.state_restore(io) }
      expect_ivars_match(original, restored, %i[@rom_bank @ram_bank @ram_enable @ram_banking_mode])
    end
  end

  describe Rubyboy::Apu do
    it 'round-trips top-level APU state and channel sub-objects' do
      original = described_class.new
      original.instance_variable_set(:@nr50, 0x77)
      original.instance_variable_set(:@nr51, 0xf3)
      original.instance_variable_set(:@cycles, 1234)
      original.instance_variable_set(:@sampling_cycles, 5678)
      original.instance_variable_set(:@fs, 5)
      original.instance_variable_set(:@sample_idx, 200)
      original.instance_variable_set(:@enabled, true)
      original.samples[0] = 0.25
      original.samples[1] = -0.5

      restored = described_class.new
      round_trip(original) { |io| restored.state_restore(io) }
      expect_ivars_match(original, restored,
                         %i[@nr50 @nr51 @cycles @sampling_cycles @fs @sample_idx @enabled])
      expect(restored.samples).to eq(original.samples)
    end
  end
end
