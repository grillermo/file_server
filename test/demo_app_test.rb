# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "rack/mock_request"
require "tmpdir"
require_relative "../lib/demo_app"

class DemoAppTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def setup
    @root = Dir.mktmpdir("file_server-demos-")
    @dir = File.join(@root, "demos")
    FileUtils.mkdir_p(@dir)
    File.write(File.join(@dir, "demo.html"), "<h1>hi</h1>")
    File.write(File.join(@root, "secret.txt"), "secret")
    @app = DemoApp.new(dir: @dir)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def request(path, method: "GET")
    @app.call(Rack::MockRequest.env_for("http://demos.example#{path}", method: method))
  end

  def read(body)
    chunks = []
    body.each { |chunk| chunks << chunk }
    chunks.join
  end

  def test_serves_a_published_file
    status, headers, body = request("/demo.html")

    assert_equal 200, status
    assert_equal "text/html", headers["content-type"]
    assert_equal "no-cache", headers["cache-control"]
    assert_equal "nosniff", headers["x-content-type-options"]
    assert_equal "<h1>hi</h1>", read(body)
  end

  def test_head_matches_get_without_a_body
    status, headers, body = request("/demo.html", method: "HEAD")

    assert_equal 200, status
    assert_equal "11", headers["content-length"]
    assert_equal "", read(body)
  end

  def test_everything_else_is_a_plain_404
    ["/", "/index", "/login", "/health", "/upload", "/files/demo.html", "/missing.html",
     "/../secret.txt", "/%2e%2e/secret.txt", "/..%2fsecret.txt", "/.hidden"].each do |path|
      status, _, body = request(path)

      assert_equal 404, status, path
      assert_equal "Not found", read(body), path
    end
  end

  def test_only_get_and_head_are_answered
    %w[POST PUT DELETE].each do |method|
      assert_equal 404, request("/demo.html", method: method).first, method
    end
  end

  def test_symlinks_are_not_followed
    File.symlink(File.join(@root, "secret.txt"), File.join(@dir, "link.txt"))

    assert_equal 404, request("/link.txt").first
  end

  def test_a_missing_demos_dir_is_just_404
    app = DemoApp.new(dir: File.join(@root, "nope"))

    assert_equal 404, app.call(Rack::MockRequest.env_for("http://demos.example/demo.html")).first
  end

  # The process behind demos.grillermo.com must not even load the upload,
  # login or token code.
  def test_demos_ru_loads_nothing_from_the_main_app
    script = <<~RUBY
      require "rack"
      app = Rack::Builder.parse_file(ARGV[0])
      puts app.class
      puts $LOADED_FEATURES.select { |f| f.start_with?(ARGV[1]) }.map { |f| File.basename(f) }.sort.inspect
    RUBY
    out, status = Open3.capture2(Gem.ruby, "-e", script, File.join(ROOT, "demos.ru"), "#{ROOT}/", chdir: ROOT)

    assert status.success?, out
    assert_equal %(DemoApp\n["demo_app.rb", "file_body.rb"]\n), out
  end
end
