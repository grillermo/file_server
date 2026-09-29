# frozen_string_literal: true

require "fileutils"
require "securerandom"

# A file is public on demos.grillermo.com when a copy of it sits in the demos
# directory, which the separate demos process serves. It's a real copy, never
# a link: that process can't reach files/, and overwriting the original later
# doesn't make the new version public by itself.
class Publisher
  class NotFound < StandardError; end

  def initialize(files_dir:, demos_dir:)
    @files_dir = files_dir
    @demos_dir = demos_dir
  end

  # The copy lands under a dot-prefixed temp name (the demos app never serves
  # dotfiles) and is renamed into place, so a half-written file is never public.
  def publish(name)
    name = safe_name(name)
    raise NotFound if name.nil?

    source = File.join(@files_dir, name)
    FileUtils.mkdir_p(@demos_dir)
    temp = File.join(@demos_dir, ".#{SecureRandom.hex(8)}.tmp")
    begin
      io = File.open(source, File::RDONLY | File::NOFOLLOW)
      raise NotFound unless io.stat.file?
      IO.copy_stream(io, temp)
      io.close
      File.rename(temp, File.join(@demos_dir, name))
    rescue Errno::ELOOP, Errno::ENOENT, Errno::EISDIR
      raise NotFound
    ensure
      FileUtils.rm_f(temp)
    end
  end

  def unpublish(name)
    path = demo_path(name)
    File.delete(path) if path && File.file?(path)
  end

  def published?(name)
    path = demo_path(name)
    !path.nil? && File.file?(path)
  end

  private

  def safe_name(name)
    name = name.to_s
    return nil if name.empty? || name.include?("\0")
    name = File.basename(name)
    return nil if name.empty? || name == "." || name == ".."
    name
  end

  def demo_path(name)
    name = safe_name(name)
    name.nil? ? nil : File.join(@demos_dir, name)
  end
end
