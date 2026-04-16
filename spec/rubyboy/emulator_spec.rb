# frozen_string_literal: true

RSpec.describe Rubyboy::Emulator do
  describe '.normalize_speed' do
    it 'returns numeric speed as a float' do
      expect(described_class.normalize_speed(2)).to eq(2.0)
      expect(described_class.normalize_speed('8')).to eq(8.0)
    end

    it 'rejects speeds below 1x and non-finite speeds' do
      expect { described_class.normalize_speed(0.5) }.to raise_error(ArgumentError)
      expect { described_class.normalize_speed(0) }.to raise_error(ArgumentError)
      expect { described_class.normalize_speed(-1) }.to raise_error(ArgumentError)
      expect { described_class.normalize_speed(Float::INFINITY) }.to raise_error(ArgumentError)
      expect { described_class.normalize_speed('fast') }.to raise_error(ArgumentError)
    end
  end
end
