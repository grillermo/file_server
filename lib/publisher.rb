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
    name = File.basename(name.to_s)
    source = File.join(@files_dir, name)
    raise NotFound, name if name.empty? || !File.file?(source)

    FileUtils.mkdir_p(@demos_dir)
    temp = File.join(@demos_dir, ".#{name}.#{SecureRandom.hex(4)}.tmp")
    begin
      IO.copy_stream(source, temp)
      File.rename(temp, File.join(@demos_dir, name))
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

  def demo_path(name)
    name = File.basename(name.to_s)
    name.empty? ? nil : File.join(@demos_dir, name)
  end
end
