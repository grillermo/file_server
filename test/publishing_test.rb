# frozen_string_literal: true

ENV["AUTH_TOKEN"] = "test-token"

require "minitest/autorun"
require "fileutils"
require "rack"
require "rack/mock_request"
require "tmpdir"
require_relative "../app"

class PublishingTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("file_server-publishing-")
    ENV["FILES_DIR"] = File.join(@dir, "files")
    ENV["DEMOS_DIR"] = File.join(@dir, "demos")
    FileUtils.mkdir_p(ENV["FILES_DIR"])
    @now = Time.at(1_000_000)
    @sent = []
    @otp = Otp.new(notifier: ->(text) { @sent << text }, clock: -> { @now })
    @session = Session.new(secret: "s" * 64, clock: -> { @now })
    @app = FileServerApp.new(otp: @otp, tokens: TokenStore.new(File.join(@dir, "tokens.json")), session: @session)
  end

  def teardown
    ENV.delete("FILES_DIR")
    ENV.delete("DEMOS_DIR")
    FileUtils.remove_entry(@dir)
  end

  # --- helpers ---------------------------------------------------------

  def request(method, path, params = {}, cookie: nil, token: nil)
    env = Rack::MockRequest.env_for("http://files.example#{path}", method: method, params: params)
    env["HTTP_COOKIE"] = "#{Session::COOKIE}=#{cookie}" if cookie
    env["HTTP_AUTHORIZATION"] = "Bearer #{token}" if token
    @app.call(env)
  end

  def body_of(body)
    chunks = []
    body.each { |chunk| chunks << chunk }
    chunks.join
  end

  def stored(name, content)
    File.write(File.join(ENV["FILES_DIR"], name), content)
  end

  def demo(name)
    File.join(ENV["DEMOS_DIR"], name)
  end

  def log_in
    request("POST", "/auth/otp", { "label" => "browser" })
    status, headers, = request("POST", "/auth/session", { "code" => @sent.last[/\d{6}/] })
    assert_equal 303, status
    headers["set-cookie"][/#{Session::COOKIE}=([^;]+)/o, 1]
  end

  # --- login -----------------------------------------------------------

  def test_login_page_sends_a_code_and_posts_it_to_auth_session
    status, headers, body = request("GET", "/login")
    html = body_of(body)

    assert_equal 200, status
    assert_equal "text/html; charset=utf-8", headers["content-type"]
    assert_includes html, %(action="/auth/session")
    assert_includes html, "/auth/otp"
  end

  def test_a_valid_code_sets_a_locked_down_cookie_and_redirects_to_the_index
    request("POST", "/auth/otp", { "label" => "browser" })
    status, headers, = request("POST", "/auth/session", { "code" => @sent.last[/\d{6}/] })
    cookie = headers["set-cookie"].downcase

    assert_equal 303, status
    assert_equal "/index", headers["location"]
    %w[httponly secure samesite=strict path=/].each { |flag| assert_includes cookie, flag }
    assert @session.valid?(headers["set-cookie"][/#{Session::COOKIE}=([^;]+)/o, 1])
  end

  def test_a_wrong_code_sets_no_cookie
    request("POST", "/auth/otp", { "label" => "browser" })
    status, headers, = request("POST", "/auth/session", { "code" => "000000" })

    assert_equal 401, status
    assert_nil headers["set-cookie"]
  end

  def test_login_without_a_session_secret_is_refused_before_using_the_code
    app = FileServerApp.new(otp: @otp, tokens: TokenStore.new(File.join(@dir, "tokens.json")),
                            session: Session.new(secret: nil))
    request("POST", "/auth/otp", { "label" => "browser" })
    code = @sent.last[/\d{6}/]
    env = Rack::MockRequest.env_for("http://files.example/auth/session", method: "POST", params: { "code" => code })

    assert_equal 503, app.call(env).first
    assert @otp.verify(code), "the code should still be usable"
  end

  def test_logout_expires_the_cookie
    status, headers, = request("POST", "/logout")

    assert_equal 303, status
    assert_includes headers["set-cookie"], "max-age=0"
  end

  # --- publish / unpublish ---------------------------------------------

  def test_publish_with_a_session_copies_the_file
    stored("demo.html", "v1")
    status, headers, = request("POST", "/publish", { "name" => "demo.html" }, cookie: log_in)

    assert_equal 303, status
    assert_equal "/index", headers["location"]
    assert_equal "v1", File.read(demo("demo.html"))
  end

  def test_publish_with_a_bearer_token
    stored("demo.html", "v1")
    status, = request("POST", "/publish", { "name" => "demo.html" }, token: "test-token")

    assert_equal 303, status
    assert File.file?(demo("demo.html"))
  end

  def test_publish_is_refused_without_auth
    stored("demo.html", "v1")

    [nil, "garbage", "#{@now.to_i + 999}.#{"0" * 64}"].each do |cookie|
      assert_equal 401, request("POST", "/publish", { "name" => "demo.html" }, cookie: cookie).first
    end
    refute File.exist?(demo("demo.html"))
  end

  def test_an_expired_session_cannot_publish
    stored("demo.html", "v1")
    cookie = log_in
    @now += Session::TTL

    assert_equal 401, request("POST", "/publish", { "name" => "demo.html" }, cookie: cookie).first
  end

  def test_unpublish_removes_the_copy_and_keeps_the_original
    stored("demo.html", "v1")
    cookie = log_in
    request("POST", "/publish", { "name" => "demo.html" }, cookie: cookie)
    status, = request("POST", "/unpublish", { "name" => "demo.html" }, cookie: cookie)

    assert_equal 303, status
    refute File.exist?(demo("demo.html"))
    assert File.file?(File.join(ENV["FILES_DIR"], "demo.html"))
  end

  def test_unpublish_is_refused_without_auth
    stored("demo.html", "v1")
    request("POST", "/publish", { "name" => "demo.html" }, token: "test-token")

    assert_equal 401, request("POST", "/unpublish", { "name" => "demo.html" }).first
    assert File.file?(demo("demo.html"))
  end

  def test_publishing_a_missing_file_is_404
    assert_equal 404, request("POST", "/publish", { "name" => "missing.html" }, token: "test-token").first
  end

  def test_reserved_and_dotfile_names_cannot_be_published
    stored("mcp.html", "x")
    stored(".env", "x")

    ["mcp.html", "MCP.HTML", ".env", ""].each do |name|
      assert_equal 422, request("POST", "/publish", { "name" => name }, token: "test-token").first, name
    end
    refute File.exist?(ENV["DEMOS_DIR"]) && !Dir.empty?(ENV["DEMOS_DIR"])
  end

  def test_a_session_cookie_does_not_authorize_uploads
    src = File.join(@dir, "src.txt")
    File.write(src, "hello")
    file = Rack::Multipart::UploadedFile.new(src, "text/plain", true, filename: "src.txt")

    assert_equal 401, request("POST", "/upload", { "file" => file }, cookie: log_in).first
  end

  # --- hardening -------------------------------------------------------

  def test_nul_byte_names_are_422
    %w[/publish /unpublish].each do |path|
      status, _, body = request("POST", path, { "name" => "a\0b" }, token: "test-token")
      assert_equal 422, status, path
      refute_includes body_of(body), "null byte"
    end
  end

  def test_filesystem_errors_do_not_leak_paths
    boom = Object.new
    boom.define_singleton_method(:publish) { |_| raise Errno::EACCES, "/secret/tmp/path" }
    @app.define_singleton_method(:publisher) { boom }
    stored("demo.html", "v1")
    status, _, body = nil
    _, err = capture_io do
      status, _, body = request("POST", "/publish", { "name" => "demo.html" }, token: "test-token")
    end

    assert_equal 500, status
    text = body_of(body)
    refute_includes text, "/secret"
    refute_includes text, @dir
    assert_includes err, "[publish]"
  end

  def test_unpublish_with_a_bearer_token
    stored("demo.html", "v1")
    request("POST", "/publish", { "name" => "demo.html" }, token: "test-token")
    status, = request("POST", "/unpublish", { "name" => "demo.html" }, token: "test-token")

    assert_equal 303, status
    refute File.exist?(demo("demo.html"))
  end

  def test_get_publish_is_404
    assert_equal 404, request("GET", "/publish", {}, token: "test-token").first
  end

  def test_unpublish_works_when_the_original_is_gone
    stored("demo.html", "v1")
    request("POST", "/publish", { "name" => "demo.html" }, token: "test-token")
    File.delete(File.join(ENV["FILES_DIR"], "demo.html"))

    assert_equal 303, request("POST", "/unpublish", { "name" => "demo.html" }, token: "test-token").first
    refute File.exist?(demo("demo.html"))
  end

  def test_unpublishing_something_not_published_is_303
    stored("demo.html", "v1")
    assert_equal 303, request("POST", "/unpublish", { "name" => "demo.html" }, token: "test-token").first
  end

  def test_republishing_updates_the_copy
    stored("demo.html", "v1")
    request("POST", "/publish", { "name" => "demo.html" }, token: "test-token")
    stored("demo.html", "v2")
    request("POST", "/publish", { "name" => "demo.html" }, token: "test-token")

    assert_equal "v2", File.read(demo("demo.html"))
  end

  def test_publishing_a_symlink_to_outside_is_404
    outside = File.join(@dir, "outside.txt")
    File.write(outside, "secret")
    File.symlink(outside, File.join(ENV["FILES_DIR"], "link.html"))

    assert_equal 404, request("POST", "/publish", { "name" => "link.html" }, token: "test-token").first
    refute File.exist?(demo("link.html"))
  end
end
