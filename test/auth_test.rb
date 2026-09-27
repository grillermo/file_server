# frozen_string_literal: true

ENV["AUTH_TOKEN"] = "test-token"

require "minitest/autorun"
require "fileutils"
require "json"
require "rack"
require "rack/mock_request"
require "tmpdir"
require_relative "../app"

class AuthTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("file_server-auth-")
    ENV["FILES_DIR"] = File.join(@dir, "files")
    @now = Time.at(1_000_000)
    @sent = []
    @otp = Otp.new(notifier: ->(text) { @sent << text }, clock: -> { @now })
    @tokens = TokenStore.new(File.join(@dir, "tokens.json"))
    @app = FileServerApp.new(otp: @otp, tokens: @tokens)
  end

  def teardown
    ENV.delete("FILES_DIR")
    FileUtils.remove_entry(@dir)
  end

  # --- helpers ---------------------------------------------------------

  def post(path, params = {}, token: nil)
    env = Rack::MockRequest.env_for("http://files.example#{path}", method: "POST", params: params)
    env["HTTP_AUTHORIZATION"] = "Bearer #{token}" if token
    @app.call(env)
  end

  def upload(token, query: "")
    src = File.join(@dir, "src.txt")
    File.write(src, "hello")
    file = Rack::Multipart::UploadedFile.new(src, "text/plain", true, filename: "src.txt")
    post("/upload#{query}", { "file" => file }, token: token)
  end

  def login(label = "laptop")
    post("/auth/otp", { "label" => label })
    status, _, body = post("/auth/verify", { "code" => @sent.last[/\d{6}/], "label" => label })
    assert_equal 200, status
    JSON.parse(body.join).fetch("token")
  end

  # --- /auth/otp ---------------------------------------------------------

  def test_otp_request_posts_the_code_to_slack
    status, _, body = post("/auth/otp", { "label" => "laptop" })

    assert_equal 202, status
    assert_equal "OTP sent to Slack #otp", body.join
    assert_match(/\Afile_server OTP: \d{6} \(for laptop\)\z/, @sent.last)
  end

  def test_otp_label_is_sanitized
    post("/auth/otp", { "label" => "<!channel> me" })

    refute_includes @sent.last, "<!channel>"
    assert_includes @sent.last, "(for channelme)"
  end

  def test_otp_without_a_label_says_unknown
    post("/auth/otp")

    assert_includes @sent.last, "(for unknown)"
  end

  def test_otp_requests_are_rate_limited
    post("/auth/otp", { "label" => "laptop" })
    status, = post("/auth/otp", { "label" => "laptop" })

    assert_equal 429, status
    assert_equal 1, @sent.size
  end

  def test_otp_without_a_webhook_is_503
    app = FileServerApp.new(otp: Otp.new(notifier: nil), tokens: @tokens)
    status, _, body = app.call(Rack::MockRequest.env_for("http://files.example/auth/otp", method: "POST"))

    assert_equal 503, status
    assert_equal "OTP delivery not configured", body.join
  end

  # --- /auth/verify ------------------------------------------------------

  def test_verify_with_the_right_code_returns_a_token
    token = login

    assert_match(/\Afts_\h{64}\z/, token)
    assert_equal "laptop", @tokens.list.first["label"]
  end

  def test_verify_with_a_wrong_code_is_401
    post("/auth/otp", { "label" => "laptop" })
    status, _, body = post("/auth/verify", { "code" => "wrong", "label" => "laptop" })

    assert_equal 401, status
    assert_equal "Invalid or expired code", body.join
  end

  def test_verify_locks_out_after_five_wrong_codes
    post("/auth/otp", { "label" => "laptop" })
    live = @sent.last[/\d{6}/]
    5.times { post("/auth/verify", { "code" => "wrong" }) }
    status, = post("/auth/verify", { "code" => live })

    assert_equal 401, status
  end

  # --- uploads -----------------------------------------------------------

  def test_upload_with_an_issued_token
    status, _, body = upload(login)

    assert_equal 200, status
    assert_includes body.join, "/files/"
  end

  def test_upload_with_auth_token_still_works
    status, = upload("test-token")

    assert_equal 200, status
  end

  def test_upload_with_an_unknown_token_is_401
    status, = upload("fts_#{"0" * 64}")

    assert_equal 401, status
  end

  def test_upload_after_revoke_is_401
    token = login
    @tokens.revoke("laptop")
    status, = upload(token)

    assert_equal 401, status
  end

  # --- reserved mcp.html -----------------------------------------------

  def test_pinned_upload_cannot_overwrite_the_install_page
    status, _, body = upload("test-token", query: "?name=mcp.html")

    assert_equal 422, status
    assert_equal "mcp.html is reserved", body.join
  end

  def test_pinned_upload_cannot_overwrite_the_install_page_regardless_of_case
    status, _, body = upload("test-token", query: "?name=MCP.html")

    assert_equal 422, status
    assert_equal "MCP.html is reserved", body.join
  end

  def test_root_redirect_skips_the_install_page
    files = ENV["FILES_DIR"]
    FileUtils.mkdir_p(files)
    File.write(File.join(files, "a.txt"), "a")
    File.write(File.join(files, "mcp.html"), "<html></html>")
    File.utime(Time.now - 60, Time.now - 60, File.join(files, "a.txt"))

    _, _, body = @app.call(Rack::MockRequest.env_for("http://files.example/", method: "GET"))

    assert_includes body.join, "/files/a.txt"
    refute_includes body.join, "mcp.html"
  end
end
