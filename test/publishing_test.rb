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
end
