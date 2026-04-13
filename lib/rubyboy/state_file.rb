# frozen_string_literal: true

require 'stringio'

module Rubyboy
  class StateFile
    MAGIC = 'RBYSTATE'
    HEADER_SIZE = 16
    FORMAT_VERSION = 1

    class Error < StandardError; end

    def self.write(path, rom:)
      payload = StringIO.new
      payload.set_encoding(Encoding::ASCII_8BIT)
      yield payload
      bytes = payload.string

      header = String.new(encoding: Encoding::ASCII_8BIT)
      header << MAGIC
      header << [FORMAT_VERSION].pack('L<')
      header << [rom.global_checksum_value].pack('S<')
      header << "\x00\x00".b

      tmp_path = "#{path}.tmp"
      File.binwrite(tmp_path, header + bytes)
      File.rename(tmp_path, path)
      true
    rescue StandardError => e
      warn "[rubyboy] failed to write state file #{path}: #{e.message}"
      false
    end

    def self.read(path, rom:)
      raise Error, "state file not found: #{path}" unless File.exist?(path)

      data = File.binread(path)
      raise Error, "state file too small: #{path}" if data.bytesize < HEADER_SIZE

      magic = data.byteslice(0, MAGIC.bytesize)
      raise Error, "state file magic mismatch (got #{magic.inspect})" unless magic == MAGIC

      format_version = data.byteslice(8, 4).unpack1('L<')
      raise Error, "state file format version #{format_version} not supported (this build understands #{FORMAT_VERSION})" unless format_version == FORMAT_VERSION

      checksum = data.byteslice(12, 2).unpack1('S<')
      expected_checksum = rom.global_checksum_value
      raise Error, "state file ROM checksum mismatch (file #{checksum}, ROM #{expected_checksum}); refusing to load" unless checksum == expected_checksum

      payload = StringIO.new(data.byteslice(HEADER_SIZE..))
      payload.set_encoding(Encoding::ASCII_8BIT)
      yield payload
      true
    rescue Error => e
      warn "[rubyboy] #{e.message}"
      false
    rescue StandardError => e
      warn "[rubyboy] failed to read state file #{path}: #{e.message}"
      false
    end
  end
end
