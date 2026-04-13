# frozen_string_literal: true

module Rubyboy
  class Ram
    attr_accessor :eram, :wram1, :wram2, :hram

    def initialize
      @eram = Array.new(0x2000, 0)
      @wram1 = Array.new(0x1000, 0)
      @wram2 = Array.new(0x1000, 0)
      @hram = Array.new(0x80, 0)
    end

    def state_dump(io)
      io.write(@eram.pack('C*'))
      io.write(@wram1.pack('C*'))
      io.write(@wram2.pack('C*'))
      io.write(@hram.pack('C*'))
    end

    def state_restore(io)
      @eram = io.read(@eram.size).unpack('C*')
      @wram1 = io.read(@wram1.size).unpack('C*')
      @wram2 = io.read(@wram2.size).unpack('C*')
      @hram = io.read(@hram.size).unpack('C*')
    end
  end
end
