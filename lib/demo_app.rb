# frozen_string_literal: true

require "rack"
require_relative "file_body"

# Everything demos.grillermo.com can do: GET or HEAD one file from the demos
# directory. It runs as its own process and requires nothing from app.rb, so
# there is no upload, login or listing code to reach through it. Anything it
# can't serve — including "/" — gets the same plain 404, so visitors can't
# tell what exists.
class DemoApp
  HEADERS = { "cache-control" => "no-cache", "x-content-type-options" => "nosniff" }.freeze

  def initialize(dir: ENV.fetch("DEMOS_DIR") { File.expand_path("../demos", __dir__) })
    @dir = dir
  end

  def call(env)
    req = Rack::Request.new(env)
    return not_found unless req.get? || req.head?

    path = demo_path(Rack::Utils.unescape_path(req.path_info.delete_prefix("/")))
    return not_found unless path

    headers = FileBody.headers(path).merge(HEADERS)
    [200, headers, req.head? ? [] : FileBody.new(path)]
  rescue StandardError => e
    warn "[demos] #{e.class}: #{e.message}"
    not_found
  end

  private

  # Only plain names directly inside the demos dir: no slashes, no dotfiles
  # (which also covers "..", and the publisher's temp files), no symlinks.
  def demo_path(name)
    return nil if name.empty? || name.include?("/") || name.include?("\0") || name.start_with?(".")

    path = File.join(@dir, name)
    File.file?(path) && !File.symlink?(path) ? path : nil
  end

  def not_found
    [404, { "content-type" => "text/plain; charset=utf-8" }, ["Not found"]]
  end
end
