# frozen_string_literal: true

require 'tmpdir'
require 'stringio'

RSpec.describe Rubyboy::StateFile do
  let(:rom) { instance_double(Rubyboy::Rom, global_checksum_value: 0x1234) }

  around do |example|
    Dir.mktmpdir('rubyboy-state-spec') do |dir|
      @tmpdir = dir
      example.run
    end
  end

  let(:path) { File.join(@tmpdir, 'pokemon.state0') }

  describe '.write' do
    it 'writes magic + format version + ROM checksum + payload' do
      described_class.write(path, rom:) { |io| io.write('hello'.b) }

      data = File.binread(path)
      expect(data.byteslice(0, 8)).to eq('RBYSTATE')
      expect(data.byteslice(8, 4).unpack1('L<')).to eq(described_class::FORMAT_VERSION)
      expect(data.byteslice(12, 2).unpack1('S<')).to eq(0x1234)
      expect(data.byteslice(16..)).to eq('hello'.b)
    end

    it 'writes atomically via .tmp + rename' do
      described_class.write(path, rom:) { |io| io.write('payload'.b) }
      expect(File.exist?(path)).to be true
      expect(File.exist?("#{path}.tmp")).to be false
    end

    it 'returns false and warns on write failure' do
      File.chmod(0o500, @tmpdir)
      expect do
        expect(described_class.write(path, rom:) { |io| io.write('x'.b) }).to be false
      end.to output(/failed to write/).to_stderr
    ensure
      File.chmod(0o700, @tmpdir)
    end
  end

  describe '.read' do
    it 'yields the payload IO when the header matches' do
      described_class.write(path, rom:) { |io| io.write('the-payload'.b) }

      seen = nil
      described_class.read(path, rom:) { |io| seen = io.read }
      expect(seen).to eq('the-payload'.b)
    end

    it 'returns false and warns when the file does not exist' do
      expect do
        expect(described_class.read(File.join(@tmpdir, 'missing.state'), rom:) { |io| io }).to be false
      end.to output(/state file not found/).to_stderr
    end

    it 'returns false and warns when the magic is wrong' do
      File.binwrite(path, "NOTSTATE#{"\x00" * 8}".b)
      expect do
        expect(described_class.read(path, rom:) { |io| io }).to be false
      end.to output(/magic mismatch/).to_stderr
    end

    it 'returns false and warns when the format version is unsupported' do
      header = +'RBYSTATE'
      header << [described_class::FORMAT_VERSION + 99].pack('L<')
      header << [0x1234].pack('S<')
      header << "\x00\x00".b
      File.binwrite(path, header)
      expect do
        expect(described_class.read(path, rom:) { |io| io }).to be false
      end.to output(/format version/).to_stderr
    end

    it 'returns false and warns when the ROM checksum does not match' do
      described_class.write(path, rom:) { |io| io.write('x'.b) }
      other_rom = instance_double(Rubyboy::Rom, global_checksum_value: 0xdead)
      expect do
        expect(described_class.read(path, rom: other_rom) { |io| io }).to be false
      end.to output(/checksum mismatch/).to_stderr
    end
  end

  describe 'round trip' do
    it 'preserves arbitrary binary payloads' do
      payload = (0..255).to_a.pack('C*')
      described_class.write(path, rom:) { |io| io.write(payload) }

      seen = nil
      described_class.read(path, rom:) { |io| seen = io.read }
      expect(seen).to eq(payload)
    end
  end
end
