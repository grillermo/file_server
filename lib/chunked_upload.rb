# frozen_string_literal: true

require "digest"
require "fileutils"

# Receives a large file in slices and puts it back together here.
#
# Request bodies past ~12 MB stall in the Cloudflare tunnel in front of
# files.chiq.me (the edge answers 524), so a client off the LAN sends a big
# file (an .ipa, say) as numbered parts with POST /upload/part, then asks for
# POST /upload/assemble. Assembling checks the total size and SHA-256 the client
# sent, writes beside the target and renames over it, so a pinned URL never
# serves a half-joined file.
#
# Parts wait in parts_dir, outside files_dir, so they are never listed or
# served. An upload that never assembles is swept after STALE_AFTER.
class ChunkedUpload
  MAX_PARTS = 1000
  STALE_AFTER = 24 * 60 * 60
  UPLOAD_ID = /\A[a-f0-9]{16,64}\z/

  Error = Class.new(StandardError)

  def initialize(parts_dir:, files_dir:)
    @parts_dir = parts_dir
    @files_dir = files_dir
  end

  # Stores part `index` (0-based) of upload `upload_id`, replacing an earlier
  # attempt at the same part, so a client can retry one part safely.
  def store_part(upload_id, index, source)
    dir = upload_dir(upload_id)
    index = part_index(index)
    sweep_stale
    FileUtils.mkdir_p(dir)
    path = File.join(dir, format("%04d", index))
    staged = "#{path}.tmp-#{Process.pid}-#{Thread.current.object_id}"
    File.open(staged, "wb") { |file| IO.copy_stream(source, file) }
    File.rename(staged, path)
    File.size(path)
  ensure
    FileUtils.rm_f(staged) if staged
  end

  # Joins parts 0...parts into files_dir/name. Returns the name.
  def assemble(upload_id, name, parts:, size:, sha256:)
    dir = upload_dir(upload_id)
    parts = Integer(parts, exception: false)
    raise Error, "parts must be between 1 and #{MAX_PARTS}" unless parts&.between?(1, MAX_PARTS)

    size = Integer(size, exception: false)
    raise Error, "size is required" unless size&.positive?
    raise Error, "sha256 is required" unless sha256.to_s.match?(/\A[a-f0-9]{64}\z/)

    paths = (0...parts).map { |i| File.join(dir, format("%04d", i)) }
    missing = paths.each_index.reject { |i| File.file?(paths[i]) }
    raise Error, "missing parts: #{missing.join(', ')}" unless missing.empty?

    FileUtils.mkdir_p(@files_dir)
    target = File.join(@files_dir, name)
    staged = File.join(@files_dir, ".#{name}.assembling-#{upload_id}")
    digest = Digest::SHA256.new
    File.open(staged, "wb") do |out|
      paths.each do |path|
        File.open(path, "rb") do |part|
          while (chunk = part.read(1 << 20))
            digest << chunk
            out.write(chunk)
          end
        end
      end
    end

    actual = File.size(staged)
    raise Error, "assembled #{actual} bytes, expected #{size}" unless actual == size
    raise Error, "sha256 mismatch" unless digest.hexdigest == sha256

    File.chmod(0o644, staged)
    File.rename(staged, target)
    FileUtils.rm_rf(dir)
    name
  ensure
    FileUtils.rm_f(staged) if staged
  end

  private

  def upload_dir(upload_id)
    raise Error, "upload_id must be 16-64 lowercase hex characters" unless upload_id.to_s.match?(UPLOAD_ID)

    File.join(@parts_dir, upload_id)
  end

  def part_index(index)
    index = Integer(index, exception: false)
    raise Error, "part must be between 0 and #{MAX_PARTS - 1}" unless index&.between?(0, MAX_PARTS - 1)

    index
  end

  def sweep_stale
    return unless File.directory?(@parts_dir)

    cutoff = Time.now - STALE_AFTER
    Dir.children(@parts_dir).each do |child|
      path = File.join(@parts_dir, child)
      FileUtils.rm_rf(path) if File.mtime(path) < cutoff
    end
  end
end
