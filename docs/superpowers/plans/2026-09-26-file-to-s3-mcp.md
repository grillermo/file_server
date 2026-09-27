# file_to_s3 MCP with Slack OTP Login Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Claude Code on any machine (including over SSH) upload a local file to `https://files.chiq.me` through a local MCP tool, after a one-time Slack-OTP login that yields a never-expiring, revocable token.

**Architecture:** Two repos. `file_to_s3` (Rack app) gains `POST /auth/otp` (posts a 6-digit code to Slack `#otp`) and `POST /auth/verify` (exchanges the code for a `fts_…` token stored as a SHA-256 digest in `tokens.json`); `/upload` accepts those tokens alongside the existing `AUTH_TOKEN`. `agents-configs` gains a stdlib-only Ruby stdio MCP server (`mcp/file-to-s3/server.rb`) with `file_to_s3_login`, `file_to_s3_verify`, `upload_file`, registered by `install.sh` via `claude mcp add --scope user`.

**Tech Stack:** Ruby 3.2 stdlib (`json`, `net/http`, `socket`, `digest`, `securerandom`), Rack 3, Minitest, POSIX sh tests.

**Spec:** `docs/superpowers/specs/2026-09-26-file-to-s3-mcp-design.md`

## Global Constraints

- MCP server: Ruby 3 **standard library only, no gems**; single file `mcp/file-to-s3/server.rb` in `/Users/grillermo/c/agents-configs`.
- `file_to_s3` adds **no new gems**; tests run with `ruby -Itest test/<name>_test.rb` (Minitest is not in the bundle; `bundle exec rake` does not work).
- OTP: 6 digits, valid **10 minutes**, one live code at a time, **30 s** minimum between issues, discarded after **5** wrong attempts.
- Slack message text: `file_to_s3 OTP: <code> (for <label>)`, posted as `{"text": ...}` JSON to `ENV["SLACK_OTP_WEBHOOK_URL"]`.
- Tokens: `fts_` + `SecureRandom.hex(32)`; **never expire**; only SHA-256 digests persisted, in `ENV.fetch("TOKENS_FILE") { <app>/tokens.json }` (gitignored, mode 0600).
- `AUTH_TOKEN` keeps working exactly as before.
- MCP config: `FILE_TO_S3_URL` (default `https://files.chiq.me`), token file `~/.config/file-to-s3/token` (override `FILE_TO_S3_TOKEN_FILE`), dir 0700 / file 0600.
- Status codes: `/auth/otp` → 202 / 429 / 503; `/auth/verify` → 200 JSON `{"token":…}` / 401 `Invalid or expired code`.
- `mcp.html` is a reserved pinned name (422) and lives tracked in git at `files/mcp.html`.
- **Never print `.env` values.** `file_to_s3/.env` already contains `SLACK_OTP_WEBHOOK_URL`; tests must inject a notifier and never hit real Slack.
- Commit in each repo separately; end commit messages with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. In `file_to_s3`, the user has unrelated uncommitted changes (`docs/superpowers/plans/2026-08-23-keyboard-in-action-viewer.md`, `test_keyboard_viewer.rb`) — never stage them; always `git add` explicit paths.

## Review Focus

1. **Relative or `~` paths in `upload_file`** — the MCP process cwd is wherever Claude was launched; `~/x` must expand to `$HOME/x`, and the error for a missing file must show the absolute path it tried (Task 6 test `test_upload_expands_tilde` / `test_upload_missing_file`).
2. **Server unreachable** (DNS failure, connection refused, laptop offline) — the tool must return `isError` with "Could not reach …", not crash the stdio loop (Task 6 `test_unreachable_server_is_a_tool_error`).
3. **Slack mention injection via `label`** — a label like `<!channel>` must not reach Slack verbatim (Task 3 `test_otp_label_is_sanitized`).
4. **`bin/tokens revoke ""` or a 1-char key** must not wipe every token (Task 1 `test_revoke_rejects_blank_key`, `test_short_key_only_matches_a_label`).
5. **Slack webhook failing** must not leave you locked out for 30 s with an undelivered code (Task 2 `test_failed_delivery_does_not_rate_limit_the_retry`).

---

## File Structure

`/Users/grillermo/c/file_to_s3`:
- Create `lib/token_store.rb` — persist/verify/list/revoke token digests.
- Create `lib/otp.rb` — in-memory single live OTP: issue, verify, rate limit, lockout.
- Create `lib/slack_notifier.rb` — POST text to a Slack incoming webhook.
- Modify `app.rb` — constructor injection, `/auth/otp`, `/auth/verify`, token-aware `authenticated?`, reserved `mcp.html`.
- Create `bin/tokens` — list/revoke CLI.
- Create `files/mcp.html` — install page; Modify `.gitignore`.
- Modify `README.md` — auth section.
- Tests: `test/token_store_test.rb`, `test/otp_test.rb`, `test/auth_test.rb`, `test/tokens_cli_test.rb`, `test/mcp_page_test.rb`.

`/Users/grillermo/c/agents-configs`:
- Create `mcp/file-to-s3/server.rb` — stdio MCP server.
- Modify `install.sh` — `register_mcp` step.
- Tests: create `tests/file-to-s3-mcp.test.rb`; modify `tests/install.test.sh`.

---

### Task 1: TokenStore

**Files:**
- Create: `/Users/grillermo/c/file_to_s3/lib/token_store.rb`
- Test: `/Users/grillermo/c/file_to_s3/test/token_store_test.rb`

**Interfaces:**
- Produces: `TokenStore.new(path)`; `#issue(label) -> String` (raw `fts_…` token); `#valid?(token) -> Boolean`; `#list -> Array<Hash{"digest","label","created_at"}>`; `#revoke(key) -> Integer` (count removed; raises `ArgumentError` on blank key). `TokenStore::PREFIX = "fts_"`.

- [ ] **Step 1: Write the failing test**

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "time"
require "tmpdir"
require_relative "../lib/token_store"

class TokenStoreTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("token-store-test-")
    @path = File.join(@dir, "nested", "tokens.json")
    @store = TokenStore.new(@path)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_issued_tokens_are_valid
    token = @store.issue("laptop")

    assert_match(/\Afts_\h{64}\z/, token)
    assert @store.valid?(token)
  end

  def test_unknown_and_blank_tokens_are_invalid
    @store.issue("laptop")

    refute @store.valid?("fts_#{"0" * 64}")
    refute @store.valid?("")
    refute @store.valid?(nil)
  end

  def test_valid_without_a_file_is_false
    refute @store.valid?("fts_#{"0" * 64}")
  end

  def test_raw_token_is_never_written
    token = @store.issue("laptop")

    refute_includes File.read(@path), token
    assert_equal 0o600, File.stat(@path).mode & 0o777
  end

  def test_tokens_survive_a_new_store_instance
    token = @store.issue("laptop")

    assert TokenStore.new(@path).valid?(token)
  end

  def test_list_shows_label_and_creation_time
    @store.issue("laptop")
    entry = @store.list.first

    assert_equal "laptop", entry["label"]
    assert Time.iso8601(entry["created_at"])
  end

  def test_revoke_by_label
    laptop = @store.issue("laptop")
    server = @store.issue("server")

    assert_equal 1, @store.revoke("laptop")
    refute @store.valid?(laptop)
    assert @store.valid?(server)
  end

  def test_revoke_by_digest_prefix
    token = @store.issue("laptop")
    prefix = @store.list.first["digest"][0, 12]

    assert_equal 1, @store.revoke(prefix)
    refute @store.valid?(token)
  end

  def test_revoke_rejects_blank_key
    token = @store.issue("laptop")

    assert_raises(ArgumentError) { @store.revoke("") }
    assert_raises(ArgumentError) { @store.revoke(nil) }
    assert @store.valid?(token)
  end

  def test_short_key_only_matches_a_label
    token = @store.issue("laptop")
    first_char = @store.list.first["digest"][0]

    assert_equal 0, @store.revoke(first_char)
    assert @store.valid?(token)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/grillermo/c/file_to_s3 && ruby -Itest test/token_store_test.rb`
Expected: FAIL — `cannot load such file -- .../lib/token_store`

- [ ] **Step 3: Write the implementation**

```ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"

# Never-expiring upload tokens issued after a Slack OTP login. Only SHA-256
# digests are persisted, so a leaked tokens.json cannot be replayed. The file is
# re-read on every check so `bin/tokens revoke` takes effect without a restart.
class TokenStore
  PREFIX = "fts_"
  # A digest prefix shorter than this could match many tokens by accident.
  MIN_DIGEST_PREFIX = 8

  def initialize(path)
    @path = path
    @mutex = Mutex.new
  end

  # Returns the raw token; this is the only time it exists outside the client.
  def issue(label)
    token = PREFIX + SecureRandom.hex(32)
    entry = { "digest" => digest(token), "label" => label, "created_at" => Time.now.utc.iso8601 }
    @mutex.synchronize { write(entries + [entry]) }
    token
  end

  def valid?(token)
    return false unless token.to_s.start_with?(PREFIX)

    wanted = digest(token)
    entries.any? { |entry| entry["digest"] == wanted }
  end

  def list
    entries
  end

  # Removes tokens whose label equals +key+ or whose digest starts with it.
  def revoke(key)
    raise ArgumentError, "revoke needs a label or a digest prefix" if key.to_s.empty?

    @mutex.synchronize do
      all = entries
      kept = all.reject { |entry| matches?(entry, key) }
      write(kept)
      all.size - kept.size
    end
  end

  private

  def matches?(entry, key)
    entry["label"] == key || (key.length >= MIN_DIGEST_PREFIX && entry["digest"].start_with?(key))
  end

  def digest(token)
    Digest::SHA256.hexdigest(token)
  end

  def entries
    File.exist?(@path) ? JSON.parse(File.read(@path)) : []
  end

  # Write-then-rename so a crash mid-write never leaves a truncated file.
  def write(list)
    FileUtils.mkdir_p(File.dirname(@path))
    tmp = "#{@path}.#{Process.pid}.tmp"
    File.write(tmp, JSON.pretty_generate(list), perm: 0o600)
    File.rename(tmp, @path)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/grillermo/c/file_to_s3 && ruby -Itest test/token_store_test.rb`
Expected: `10 runs, ... 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
cd /Users/grillermo/c/file_to_s3
git add lib/token_store.rb test/token_store_test.rb
git commit -m "feat: add digest-only TokenStore for MCP tokens

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Otp and SlackNotifier

**Files:**
- Create: `/Users/grillermo/c/file_to_s3/lib/otp.rb`
- Create: `/Users/grillermo/c/file_to_s3/lib/slack_notifier.rb`
- Test: `/Users/grillermo/c/file_to_s3/test/otp_test.rb`

**Interfaces:**
- Produces: `Otp.new(notifier:, clock: -> { Time.now })` where `notifier` is `nil` or anything responding to `call(text)`; `#issue(label)` (raises `Otp::NotConfigured`, `Otp::TooSoon`, or re-raises the notifier's error); `#verify(code) -> Boolean`; constants `Otp::TTL = 600`, `Otp::MIN_INTERVAL = 30`, `Otp::MAX_ATTEMPTS = 5`.
- Produces: `SlackNotifier.from_env -> SlackNotifier | nil` (nil when `SLACK_OTP_WEBHOOK_URL` blank); `SlackNotifier.new(url)#call(text)` (raises `RuntimeError` on non-2xx).

- [ ] **Step 1: Write the failing test**

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "socket"
require_relative "../lib/otp"
require_relative "../lib/slack_notifier"

class OtpTest < Minitest::Test
  def setup
    @now = Time.at(1_000_000)
    @sent = []
    @otp = Otp.new(notifier: ->(text) { @sent << text }, clock: -> { @now })
  end

  def code
    @sent.last[/\d{6}/]
  end

  def test_issue_sends_a_six_digit_code_with_the_label
    @otp.issue("laptop")

    assert_match(/\Afile_to_s3 OTP: \d{6} \(for laptop\)\z/, @sent.last)
  end

  def test_correct_code_verifies_exactly_once
    @otp.issue("laptop")
    live = code

    assert @otp.verify(live)
    refute @otp.verify(live)
  end

  def test_wrong_code_fails
    @otp.issue("laptop")

    refute @otp.verify("wrong")
  end

  def test_verify_without_an_issued_code_fails
    refute @otp.verify("123456")
  end

  def test_expired_code_fails
    @otp.issue("laptop")
    live = code
    @now += Otp::TTL

    refute @otp.verify(live)
  end

  def test_four_wrong_attempts_still_allow_the_right_code
    @otp.issue("laptop")
    live = code
    4.times { refute @otp.verify("wrong") }

    assert @otp.verify(live)
  end

  def test_fifth_wrong_attempt_discards_the_code
    @otp.issue("laptop")
    live = code
    5.times { refute @otp.verify("wrong") }

    refute @otp.verify(live)
  end

  def test_second_issue_within_the_interval_is_too_soon
    @otp.issue("laptop")
    @now += Otp::MIN_INTERVAL - 1

    assert_raises(Otp::TooSoon) { @otp.issue("laptop") }
    assert_equal 1, @sent.size
  end

  def test_new_code_replaces_the_old_one
    @otp.issue("laptop")
    old = code
    @now += Otp::MIN_INTERVAL
    @otp.issue("laptop")

    refute @otp.verify(old) unless old == code
    assert @otp.verify(code)
  end

  def test_without_a_notifier_issue_is_not_configured
    otp = Otp.new(notifier: nil)

    assert_raises(Otp::NotConfigured) { otp.issue("laptop") }
  end

  def test_failed_delivery_does_not_rate_limit_the_retry
    failing = true
    otp = Otp.new(notifier: ->(text) { failing ? raise("slack down") : @sent << text }, clock: -> { @now })

    assert_raises(RuntimeError) { otp.issue("laptop") }
    failing = false
    otp.issue("laptop")

    assert otp.verify(code)
  end
end

class SlackNotifierTest < Minitest::Test
  def test_from_env_is_nil_when_the_webhook_is_blank
    with_env("SLACK_OTP_WEBHOOK_URL" => "  ") { assert_nil SlackNotifier.from_env }
    with_env("SLACK_OTP_WEBHOOK_URL" => nil) { assert_nil SlackNotifier.from_env }
  end

  def test_call_posts_json_text
    server = TCPServer.new("127.0.0.1", 0)
    received = Thread.new do
      client = server.accept
      headers = {}
      client.gets
      while (line = client.gets) != "\r\n"
        name, value = line.split(":", 2)
        headers[name.downcase] = value.strip
      end
      body = client.read(headers["content-length"].to_i)
      client.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
      client.close
      body
    end

    SlackNotifier.new("http://127.0.0.1:#{server.addr[1]}/hook").call("hi")

    assert_equal({ "text" => "hi" }, JSON.parse(received.value))
  ensure
    server&.close
  end

  private

  def with_env(vars)
    saved = vars.keys.to_h { |key| [key, ENV[key]] }
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| ENV[key] = value }
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/grillermo/c/file_to_s3 && ruby -Itest test/otp_test.rb`
Expected: FAIL — `cannot load such file -- .../lib/otp`

- [ ] **Step 3: Write the implementation**

`lib/slack_notifier.rb`:

```ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

# Posts a message to a Slack incoming webhook — the same call rulinky's
# SlackOtpNotifier makes, pointed at the #otp channel.
class SlackNotifier
  def self.from_env
    url = ENV["SLACK_OTP_WEBHOOK_URL"].to_s.strip
    url.empty? ? nil : new(url)
  end

  def initialize(url)
    @uri = URI(url)
  end

  def call(text)
    response = Net::HTTP.post(@uri, { text: text }.to_json, "Content-Type" => "application/json")
    raise "Slack webhook returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)
  end
end
```

`lib/otp.rb`:

```ruby
# frozen_string_literal: true

require "rack/utils"
require "securerandom"

# The single live login code. Held in memory: the app is one process and has
# one user, so a restart simply voids a pending code.
class Otp
  TTL = 600
  MIN_INTERVAL = 30
  MAX_ATTEMPTS = 5

  class NotConfigured < StandardError; end
  class TooSoon < StandardError; end

  def initialize(notifier:, clock: -> { Time.now })
    @notifier = notifier
    @clock = clock
    @mutex = Mutex.new
    @code = nil
    @issued_at = nil
  end

  # Replaces any live code with a new one and delivers it. A failed delivery
  # voids the code and the rate limit, so an immediate retry is allowed.
  def issue(label)
    raise NotConfigured unless @notifier

    code = @mutex.synchronize { generate }
    @notifier.call("file_to_s3 OTP: #{code} (for #{label})")
  rescue NotConfigured, TooSoon
    raise
  rescue StandardError
    @mutex.synchronize { @code = @issued_at = nil }
    raise
  end

  # True at most once per code; MAX_ATTEMPTS wrong guesses discard it.
  def verify(candidate)
    @mutex.synchronize do
      return false unless @code && @clock.call < @expires_at

      if Rack::Utils.secure_compare(@code, candidate.to_s)
        @code = nil
        return true
      end

      @attempts += 1
      @code = nil if @attempts >= MAX_ATTEMPTS
      false
    end
  end

  private

  def generate
    now = @clock.call
    raise TooSoon if @issued_at && now - @issued_at < MIN_INTERVAL

    @issued_at = now
    @expires_at = now + TTL
    @attempts = 0
    @code = format("%06d", SecureRandom.random_number(1_000_000))
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/grillermo/c/file_to_s3 && ruby -Itest test/otp_test.rb`
Expected: `13 runs, ... 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
cd /Users/grillermo/c/file_to_s3
git add lib/otp.rb lib/slack_notifier.rb test/otp_test.rb
git commit -m "feat: add Slack-delivered OTP with rate limit and lockout

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Auth endpoints and token-aware uploads in the app

**Files:**
- Modify: `/Users/grillermo/c/file_to_s3/app.rb` (requires at top; class body: new `initialize`, routes in `call`, `authenticated?`, `handle_upload`, `latest_filename`, new private methods)
- Modify: `/Users/grillermo/c/file_to_s3/README.md` (add "MCP login" section)
- Test: `/Users/grillermo/c/file_to_s3/test/auth_test.rb`

**Interfaces:**
- Consumes: `Otp`, `Otp::NotConfigured`, `Otp::TooSoon`, `Otp::MIN_INTERVAL`, `SlackNotifier.from_env` (Task 2); `TokenStore` (Task 1).
- Produces: `FileToS3App.new(otp: Otp, tokens: TokenStore)` — both keyword args optional (defaults: `Otp.new(notifier: SlackNotifier.from_env)`, `TokenStore.new(ENV.fetch("TOKENS_FILE") { File.join(__dir__, "tokens.json") })`); `FileToS3App::RESERVED_NAMES = ["mcp.html"]`. HTTP: `POST /auth/otp` (`label`), `POST /auth/verify` (`code`, `label`).

- [ ] **Step 1: Write the failing test**

```ruby
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
    @dir = Dir.mktmpdir("file-to-s3-auth-")
    ENV["FILES_DIR"] = File.join(@dir, "files")
    @now = Time.at(1_000_000)
    @sent = []
    @otp = Otp.new(notifier: ->(text) { @sent << text }, clock: -> { @now })
    @tokens = TokenStore.new(File.join(@dir, "tokens.json"))
    @app = FileToS3App.new(otp: @otp, tokens: @tokens)
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
    post("/auth/otp", "label" => label)
    status, _, body = post("/auth/verify", "code" => @sent.last[/\d{6}/], "label" => label)
    assert_equal 200, status
    JSON.parse(body.join).fetch("token")
  end

  # --- /auth/otp ---------------------------------------------------------

  def test_otp_request_posts_the_code_to_slack
    status, _, body = post("/auth/otp", "label" => "laptop")

    assert_equal 202, status
    assert_equal "OTP sent to Slack #otp", body.join
    assert_match(/\Afile_to_s3 OTP: \d{6} \(for laptop\)\z/, @sent.last)
  end

  def test_otp_label_is_sanitized
    post("/auth/otp", "label" => "<!channel> me")

    refute_includes @sent.last, "<!channel>"
    assert_includes @sent.last, "(for channelme)"
  end

  def test_otp_without_a_label_says_unknown
    post("/auth/otp")

    assert_includes @sent.last, "(for unknown)"
  end

  def test_otp_requests_are_rate_limited
    post("/auth/otp", "label" => "laptop")
    status, = post("/auth/otp", "label" => "laptop")

    assert_equal 429, status
    assert_equal 1, @sent.size
  end

  def test_otp_without_a_webhook_is_503
    app = FileToS3App.new(otp: Otp.new(notifier: nil), tokens: @tokens)
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
    post("/auth/otp", "label" => "laptop")
    status, _, body = post("/auth/verify", "code" => "wrong", "label" => "laptop")

    assert_equal 401, status
    assert_equal "Invalid or expired code", body.join
  end

  def test_verify_locks_out_after_five_wrong_codes
    post("/auth/otp", "label" => "laptop")
    live = @sent.last[/\d{6}/]
    5.times { post("/auth/verify", "code" => "wrong") }
    status, = post("/auth/verify", "code" => live)

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/grillermo/c/file_to_s3 && ruby -Itest test/auth_test.rb`
Expected: FAIL — `ArgumentError: unknown keywords: otp, tokens` (errors in every test)

- [ ] **Step 3: Write the implementation**

In `app.rb`, after `require "uri"` add:

```ruby
require_relative "lib/otp"
require_relative "lib/slack_notifier"
require_relative "lib/token_store"
```

At the top of `class FileToS3App`, before `def call(env)`:

```ruby
  # Served from files/ like any upload, but owned by the repo.
  RESERVED_NAMES = ["mcp.html"].freeze

  def initialize(otp: Otp.new(notifier: SlackNotifier.from_env),
                 tokens: TokenStore.new(ENV.fetch("TOKENS_FILE") { File.join(__dir__, "tokens.json") }))
    @otp = otp
    @tokens = tokens
  end
```

In `call`, add these two branches directly after the `in ["POST", "/receive"]` branch:

```ruby
    in ["POST", "/auth/otp"]
      request_otp(req)
    in ["POST", "/auth/verify"]
      verify_otp(req)
```

Replace `authenticated?`:

```ruby
  # AUTH_TOKEN is the Shortcuts' shared secret; fts_ tokens come from an MCP
  # login and never expire until revoked with bin/tokens.
  def authenticated?(req)
    token = bearer_token(req)
    return false unless token

    Rack::Utils.secure_compare(token, ENV.fetch("AUTH_TOKEN")) || @tokens.valid?(token)
  end
```

In `handle_upload`, directly after `pinned = pinned_name(req)` add:

```ruby
    return unprocessable("#{pinned} is reserved") if RESERVED_NAMES.include?(pinned)
```

In `latest_filename`, change the `.select` line to:

```ruby
      .select { |path| File.file?(path) && !RESERVED_NAMES.include?(File.basename(path)) }
```

Add these private methods after `bearer_token`:

```ruby
  def request_otp(req)
    @otp.issue(otp_label(req))
    text_response(202, "OTP sent to Slack #otp")
  rescue Otp::NotConfigured
    text_response(503, "OTP delivery not configured")
  rescue Otp::TooSoon
    text_response(429, "An OTP was sent less than #{Otp::MIN_INTERVAL}s ago; check Slack #otp")
  end

  def verify_otp(req)
    return text_response(401, "Invalid or expired code") unless @otp.verify(req.params["code"].to_s.strip)

    token = @tokens.issue(otp_label(req))
    [200, { "content-type" => "application/json" }, [{ token: token }.to_json]]
  end

  # The label ends up in a Slack message, so strip anything that could form a
  # mention or link (<!channel>, <@U123>) and cap its length.
  def otp_label(req)
    label = req.params["label"].to_s.gsub(/[^\w.\-]/, "")[0, 64]
    label.empty? ? "unknown" : label
  end
```

In `README.md`, append:

````markdown
## MCP login

The `file-to-s3` MCP in `agents-configs` logs in with a Slack OTP and then
uploads with a token that never expires. Install instructions are served at
`/files/mcp.html`.

- `POST /auth/otp` (`label`) posts a 6-digit code to Slack `#otp`
  (needs `SLACK_OTP_WEBHOOK_URL` in `.env`). 202, or 429 within 30 s of the last code.
- `POST /auth/verify` (`code`, `label`) returns `{"token":"fts_..."}`. Five wrong
  codes void the current one.
- Tokens are stored as SHA-256 digests in `tokens.json` (`TOKENS_FILE` overrides).

```sh
bin/tokens list
bin/tokens revoke <label|digest-prefix>
```
````

- [ ] **Step 4: Run all app tests to verify they pass**

Run: `cd /Users/grillermo/c/file_to_s3 && for t in test/*_test.rb; do ruby -Itest "$t" || exit 1; done`
Expected: every file reports `0 failures, 0 errors` (including the pre-existing `test/app_test.rb`, 16 runs).

- [ ] **Step 5: Commit**

```bash
cd /Users/grillermo/c/file_to_s3
git add app.rb README.md test/auth_test.rb
git commit -m "feat: add Slack OTP login issuing upload tokens

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `bin/tokens` CLI

**Files:**
- Create: `/Users/grillermo/c/file_to_s3/bin/tokens` (executable)
- Test: `/Users/grillermo/c/file_to_s3/test/tokens_cli_test.rb`

**Interfaces:**
- Consumes: `TokenStore#list`, `#revoke`, `#issue` (Task 1).
- Produces: `bin/tokens list` prints `label<TAB>created_at<TAB>digest[0,12]` per token; `bin/tokens revoke KEY` prints `revoked N`; bad usage exits 64.

- [ ] **Step 1: Write the failing test**

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../lib/token_store"

class TokensCliTest < Minitest::Test
  BIN = File.expand_path("../bin/tokens", __dir__)

  def setup
    @dir = Dir.mktmpdir("tokens-cli-test-")
    @path = File.join(@dir, "tokens.json")
    @store = TokenStore.new(@path)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def run_cli(*args)
    Open3.capture3({ "TOKENS_FILE" => @path }, RbConfig.ruby, BIN, *args)
  end

  def test_list_prints_label_date_and_digest_prefix
    @store.issue("laptop")
    out, _, status = run_cli("list")

    assert status.success?
    label, created_at, prefix = out.chomp.split("\t")
    assert_equal "laptop", label
    refute_empty created_at
    assert_equal @store.list.first["digest"][0, 12], prefix
  end

  def test_revoke_removes_the_token
    token = @store.issue("laptop")
    out, _, status = run_cli("revoke", "laptop")

    assert status.success?
    assert_equal "revoked 1\n", out
    refute @store.valid?(token)
  end

  def test_bad_usage_exits_64
    _, err, status = run_cli
    assert_equal 64, status.exitstatus
    assert_includes err, "usage:"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/grillermo/c/file_to_s3 && ruby -Itest test/tokens_cli_test.rb`
Expected: FAIL — non-success status / `No such file or directory` for `bin/tokens`

- [ ] **Step 3: Write the implementation**

`bin/tokens`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

# Lists or revokes the never-expiring tokens issued by MCP logins.
#   bin/tokens list
#   bin/tokens revoke <label|digest-prefix>

require_relative "../lib/token_store"

store = TokenStore.new(ENV.fetch("TOKENS_FILE") { File.expand_path("../tokens.json", __dir__) })

case ARGV
in ["list"]
  store.list.each { |entry| puts [entry["label"], entry["created_at"], entry["digest"][0, 12]].join("\t") }
in ["revoke", key] unless key.empty?
  puts "revoked #{store.revoke(key)}"
else
  warn "usage: bin/tokens list | bin/tokens revoke <label|digest-prefix>"
  exit 64
end
```

Then: `chmod +x /Users/grillermo/c/file_to_s3/bin/tokens`

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/grillermo/c/file_to_s3 && ruby -Itest test/tokens_cli_test.rb`
Expected: `3 runs, ... 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
cd /Users/grillermo/c/file_to_s3
git add bin/tokens test/tokens_cli_test.rb
git commit -m "feat: add bin/tokens to list and revoke MCP tokens

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Install page `files/mcp.html` + `.gitignore`

**Files:**
- Create: `/Users/grillermo/c/file_to_s3/files/mcp.html`
- Modify: `/Users/grillermo/c/file_to_s3/.gitignore` (replace `files/` line; add `tokens.json`)
- Test: `/Users/grillermo/c/file_to_s3/test/mcp_page_test.rb`

**Interfaces:**
- Consumes: `FileToS3App` serving `/files/<name>` from `FILES_DIR` (existing).

Note: git cannot re-include a file under an ignored *directory*, so `files/` must become `files/*` for `!files/mcp.html` to work.

- [ ] **Step 1: Write the failing test**

```ruby
# frozen_string_literal: true

ENV["AUTH_TOKEN"] = "test-token"

require "minitest/autorun"
require "open3"
require "rack"
require "rack/mock_request"
require_relative "../app"

class McpPageTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PAGE = File.join(ROOT, "files", "mcp.html")

  def test_page_has_the_copy_pasteable_install_commands
    html = File.read(PAGE)

    assert_includes html, "git clone git@github.com:grillermo/agents-configs.git ~/c/agents-configs"
    assert_includes html, "~/c/agents-configs/install.sh"
    assert_includes html, "cd ~/c/agents-configs &amp;&amp; git pull &amp;&amp; ./install.sh"
    assert_includes html, "claude mcp add --scope user file-to-s3 -- ruby ~/c/agents-configs/mcp/file-to-s3/server.rb"
    assert_includes html, "bin/tokens revoke"
  end

  def test_page_is_served_as_html
    ENV["FILES_DIR"] = File.dirname(PAGE)
    status, headers, = FileToS3App.new.call(Rack::MockRequest.env_for("http://files.example/files/mcp.html"))

    assert_equal 200, status
    assert_equal "text/html", headers["content-type"]
  ensure
    ENV.delete("FILES_DIR")
  end

  def test_page_is_tracked_and_tokens_are_ignored
    _, _, tracked = Open3.capture3("git", "check-ignore", "-q", "files/mcp.html", chdir: ROOT)
    _, _, ignored = Open3.capture3("git", "check-ignore", "-q", "tokens.json", chdir: ROOT)

    refute tracked.success?, "files/mcp.html must not be gitignored"
    assert ignored.success?, "tokens.json must be gitignored"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/grillermo/c/file_to_s3 && ruby -Itest test/mcp_page_test.rb`
Expected: FAIL — `Errno::ENOENT ... files/mcp.html` and the gitignore assertions fail.

- [ ] **Step 3: Write the page and gitignore**

`.gitignore` — replace the `files/` line with the three lines below (keep every other line):

```
files/*
!files/mcp.html
tokens.json
```

`files/mcp.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>file-to-s3 MCP</title>
<style>
  :root { color-scheme: light dark; --bg: #f6f6f7; --card: #fff; --fg: #16161a; --dim: #74747e; --line: #e3e3e7; --accent: #2f6fed; --code: #f0f0f3; }
  @media (prefers-color-scheme: dark) {
    :root { --bg: #111114; --card: #1b1b20; --fg: #f2f2f4; --dim: #9a9aa4; --line: #2a2a32; --accent: #7ea6ff; --code: #24242b; }
  }
  * { box-sizing: border-box; }
  body { margin: 0; padding: 1rem 1rem 3rem; background: var(--bg); color: var(--fg);
         font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
  main { max-width: 46rem; margin: 0 auto; }
  h1 { font-size: 1.25rem; margin: .25rem 0 .25rem; }
  h2 { font-size: 1rem; margin: 1.75rem 0 .5rem; }
  p, li { color: var(--fg); }
  .dim { color: var(--dim); font-size: .9rem; }
  .cmd { position: relative; background: var(--card); border: 1px solid var(--line); border-radius: 10px; margin: .5rem 0; }
  .cmd pre { margin: 0; padding: .8rem 4.5rem .8rem 1rem; overflow-x: auto; background: var(--code); border-radius: 10px;
             font: 13px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre; }
  .cmd button { position: absolute; top: .45rem; right: .45rem; border: 1px solid var(--line); background: var(--card);
                color: var(--accent); border-radius: 6px; padding: .2rem .6rem; font: inherit; font-size: .8rem; cursor: pointer; }
  code { font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; }
  ol { padding-left: 1.25rem; }
  @media (min-width: 40rem) { body { padding: 2rem 1.5rem 4rem; } }
</style>
</head>
<body>
<main>
<h1>file-to-s3 MCP</h1>
<p class="dim">Lets Claude Code upload local files to files.chiq.me. Log in once per machine with a code from Slack #otp; the token never expires.</p>

<h2>New machine</h2>
<div class="cmd"><pre>git clone git@github.com:grillermo/agents-configs.git ~/c/agents-configs
~/c/agents-configs/install.sh</pre><button type="button">Copy</button></div>

<h2>Already have agents-configs</h2>
<div class="cmd"><pre>cd ~/c/agents-configs &amp;&amp; git pull &amp;&amp; ./install.sh</pre><button type="button">Copy</button></div>

<h2>Without install.sh</h2>
<div class="cmd"><pre>claude mcp add --scope user file-to-s3 -- ruby ~/c/agents-configs/mcp/file-to-s3/server.rb</pre><button type="button">Copy</button></div>

<h2>Log in and upload</h2>
<ol>
  <li>In Claude Code: <code>log in to file_to_s3</code></li>
  <li>Paste the 6-digit code posted to Slack <strong>#otp</strong>.</li>
  <li><code>upload ~/path/to/file</code> — Claude replies with the URL.</li>
</ol>
<p class="dim">Needs Ruby 3. Point at another server with <code>FILE_TO_S3_URL</code>. The token lives in <code>~/.config/file-to-s3/token</code>.</p>

<h2>Revoke a machine (on the server)</h2>
<div class="cmd"><pre>bin/tokens list
bin/tokens revoke &lt;hostname&gt;</pre><button type="button">Copy</button></div>
</main>
<script>
  document.querySelectorAll(".cmd button").forEach((button) => {
    button.addEventListener("click", async () => {
      const text = button.previousElementSibling.textContent;
      try {
        await navigator.clipboard.writeText(text);
        button.textContent = "Copied";
      } catch {
        const range = document.createRange();
        range.selectNodeContents(button.previousElementSibling);
        getSelection().removeAllRanges();
        getSelection().addRange(range);
        button.textContent = "Selected";
      }
      setTimeout(() => { button.textContent = "Copy"; }, 1500);
    });
  });
</script>
</body>
</html>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/grillermo/c/file_to_s3 && ruby -Itest test/mcp_page_test.rb`
Expected: `3 runs, ... 0 failures, 0 errors`

Also check nothing else under `files/` became tracked: `git status --short files/` shows only `?? files/mcp.html`.

- [ ] **Step 5: Commit**

```bash
cd /Users/grillermo/c/file_to_s3
git add .gitignore files/mcp.html test/mcp_page_test.rb
git commit -m "feat: add MCP install page at /files/mcp.html

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Local stdio MCP server in agents-configs

**Files:**
- Create: `/Users/grillermo/c/agents-configs/mcp/file-to-s3/server.rb` (executable)
- Test: `/Users/grillermo/c/agents-configs/tests/file-to-s3-mcp.test.rb`

**Interfaces:**
- Consumes (HTTP, from Tasks 3): `POST /auth/otp` form `label` → 202; `POST /auth/verify` form `code`,`label` → 200 `{"token":…}` / 401; `POST /upload[?name=…]` multipart `file`, `Authorization: Bearer` → 200 body = URL / 401 / 422.
- Produces: MCP tools `file_to_s3_login` (no args), `file_to_s3_verify` (`code`), `upload_file` (`path`, optional `name`). Env: `FILE_TO_S3_URL`, `FILE_TO_S3_TOKEN_FILE`.

- [ ] **Step 1: Write the failing test**

```ruby
# frozen_string_literal: true

# Run: ruby tests/file-to-s3-mcp.test.rb
require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "socket"
require "tmpdir"
require "uri"

SERVER = File.expand_path("../mcp/file-to-s3/server.rb", __dir__)

# A just-enough HTTP/1.1 server standing in for files.chiq.me. WEBrick is not
# in Ruby 3's stdlib, so this reads one request per connection by hand.
class FakeFileToS3
  attr_reader :requests, :url

  def initialize(&responder)
    @responder = responder
    @requests = []
    @server = TCPServer.new("127.0.0.1", 0)
    @url = "http://127.0.0.1:#{@server.addr[1]}"
    @thread = Thread.new { loop { serve(@server.accept) } }
  end

  def stop
    @thread.kill
    @server.close
  end

  private

  def serve(socket)
    method, target, = socket.gets.to_s.split(" ")
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.strip
    end
    request = { method: method, path: target, headers: headers, body: socket.read(headers["content-length"].to_i) }
    @requests << request
    status, text = @responder.call(request)
    socket.write("HTTP/1.1 #{status} X\r\nContent-Type: text/plain\r\nContent-Length: #{text.bytesize}\r\nConnection: close\r\n\r\n#{text}")
  ensure
    socket.close
  end
end

class FileToS3McpTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("file-to-s3-mcp-")
    @token_file = File.join(@dir, "config", "file-to-s3", "token")
    @routes = {}
    @fake = FakeFileToS3.new do |request|
      handler = @routes[request[:path].split("?").first]
      handler ? handler.call(request) : [404, "Not found"]
    end
    @url = @fake.url
  end

  def teardown
    @fake.stop
    FileUtils.remove_entry(@dir)
  end

  # --- helpers ---------------------------------------------------------

  def raw(input)
    env = { "FILE_TO_S3_URL" => @url, "FILE_TO_S3_TOKEN_FILE" => @token_file, "HOME" => @dir }
    out, err, status = Open3.capture3(env, RbConfig.ruby, SERVER, stdin_data: input)
    assert status.success?, "server exited #{status.exitstatus}: #{err}"
    out.lines.map { |line| JSON.parse(line) }
  end

  def mcp(*messages)
    raw(messages.map { |message| JSON.generate(message) }.join("\n") + "\n")
  end

  def call_tool(name, arguments = {})
    mcp({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } })
      .last.fetch("result")
  end

  def text(result)
    result.fetch("content").first.fetch("text")
  end

  def logged_in(token = "fts_abc")
    FileUtils.mkdir_p(File.dirname(@token_file))
    File.write(@token_file, "#{token}\n")
  end

  def write_file(name, content)
    path = File.join(@dir, name)
    File.write(path, content)
    path
  end

  # --- protocol ----------------------------------------------------------

  def test_initialize_then_list_tools
    responses = mcp(
      { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "0" } } },
      { jsonrpc: "2.0", method: "notifications/initialized" },
      { jsonrpc: "2.0", id: 2, method: "tools/list" }
    )

    assert_equal [1, 2], responses.map { |response| response["id"] }
    assert_equal "2025-06-18", responses[0]["result"]["protocolVersion"]
    assert_equal "file-to-s3", responses[0]["result"]["serverInfo"]["name"]
    assert_equal({ "tools" => {} }, responses[0]["result"]["capabilities"])
    names = responses[1]["result"]["tools"].map { |tool| tool["name"] }
    assert_equal %w[file_to_s3_login file_to_s3_verify upload_file], names
    upload = responses[1]["result"]["tools"].find { |tool| tool["name"] == "upload_file" }
    assert_equal %w[path name], upload["inputSchema"]["properties"].keys
    assert_equal %w[path], upload["inputSchema"]["required"]
  end

  def test_ping
    assert_equal({}, mcp({ jsonrpc: "2.0", id: 7, method: "ping" }).first["result"])
  end

  def test_unknown_method_is_an_error
    response = mcp({ jsonrpc: "2.0", id: 3, method: "resources/list" }).first

    assert_equal(-32601, response["error"]["code"])
  end

  def test_bad_json_is_reported_and_the_server_keeps_going
    responses = raw("not json\n#{JSON.generate(jsonrpc: "2.0", id: 4, method: "ping")}\n")

    assert_equal(-32700, responses[0]["error"]["code"])
    assert_equal 4, responses[1]["id"]
  end

  # --- login -------------------------------------------------------------

  def test_login_requests_an_otp_labelled_with_the_hostname
    @routes["/auth/otp"] = ->(_) { [202, "OTP sent to Slack #otp"] }
    result = call_tool("file_to_s3_login")

    assert_equal false, result["isError"]
    assert_includes text(result), "Slack #otp"
    assert_includes text(result), "file_to_s3_verify"
    assert_includes @fake.requests.last[:body], URI.encode_www_form(label: Socket.gethostname)
  end

  def test_login_failure_is_a_tool_error
    @routes["/auth/otp"] = ->(_) { [503, "OTP delivery not configured"] }
    result = call_tool("file_to_s3_login")

    assert_equal true, result["isError"]
    assert_includes text(result), "OTP delivery not configured"
  end

  def test_verify_saves_the_token_privately
    @routes["/auth/verify"] = ->(_) { [200, JSON.generate(token: "fts_abc")] }
    result = call_tool("file_to_s3_verify", code: " 123456 ")

    assert_equal false, result["isError"]
    assert_includes @fake.requests.last[:body], "code=123456"
    assert_equal "fts_abc", File.read(@token_file)
    assert_equal 0o600, File.stat(@token_file).mode & 0o777
    assert_equal 0o700, File.stat(File.dirname(@token_file)).mode & 0o777
  end

  def test_rejected_code_writes_no_token
    @routes["/auth/verify"] = ->(_) { [401, "Invalid or expired code"] }
    result = call_tool("file_to_s3_verify", code: "000000")

    assert_equal true, result["isError"]
    assert_includes text(result), "Invalid or expired code"
    refute File.exist?(@token_file)
  end

  # --- upload ------------------------------------------------------------

  def test_upload_returns_the_url
    logged_in
    @routes["/upload"] = ->(_) { [200, "https://files.example/files/uuid-a.txt"] }
    result = call_tool("upload_file", path: write_file("a.txt", "hello"))

    assert_equal false, result["isError"]
    assert_equal "https://files.example/files/uuid-a.txt", text(result)
    request = @fake.requests.last
    assert_equal "Bearer fts_abc", request[:headers]["authorization"]
    assert_includes request[:body], %(filename="a.txt")
    assert_includes request[:body], "hello"
  end

  def test_upload_with_a_pinned_name
    logged_in
    @routes["/upload"] = ->(_) { [200, "https://files.example/files/stable.txt"] }
    call_tool("upload_file", path: write_file("a.txt", "hello"), name: "stable.txt")

    assert_equal "/upload?name=stable.txt", @fake.requests.last[:path]
  end

  def test_upload_expands_tilde
    logged_in
    write_file("home.txt", "hi")
    @routes["/upload"] = ->(_) { [200, "https://files.example/files/uuid-home.txt"] }
    result = call_tool("upload_file", path: "~/home.txt")

    assert_equal false, result["isError"], text(result)
  end

  def test_upload_without_a_token_asks_to_log_in
    result = call_tool("upload_file", path: write_file("a.txt", "hello"))

    assert_equal true, result["isError"]
    assert_includes text(result), "file_to_s3_login"
    assert_empty @fake.requests
  end

  def test_upload_with_a_rejected_token_asks_to_log_in
    logged_in
    @routes["/upload"] = ->(_) { [401, "Unauthorized"] }
    result = call_tool("upload_file", path: write_file("a.txt", "hello"))

    assert_equal true, result["isError"]
    assert_includes text(result), "file_to_s3_login"
  end

  def test_upload_missing_file
    logged_in
    result = call_tool("upload_file", path: "nope.txt")

    assert_equal true, result["isError"]
    assert_includes text(result), "Not a readable file"
    assert_includes text(result), "/nope.txt"
  end

  def test_upload_server_error_is_passed_through
    logged_in
    @routes["/upload"] = ->(_) { [422, "mcp.html is reserved"] }
    result = call_tool("upload_file", path: write_file("a.txt", "x"), name: "mcp.html")

    assert_equal true, result["isError"]
    assert_includes text(result), "mcp.html is reserved"
  end

  def test_unreachable_server_is_a_tool_error
    logged_in
    @url = "http://127.0.0.1:1"
    result = call_tool("upload_file", path: write_file("a.txt", "x"))

    assert_equal true, result["isError"]
    assert_includes text(result), "Could not reach"
  end

  def test_unknown_tool_is_a_tool_error
    result = call_tool("delete_everything")

    assert_equal true, result["isError"]
    assert_includes text(result), "Unknown tool"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/grillermo/c/agents-configs && ruby tests/file-to-s3-mcp.test.rb`
Expected: FAIL — every test errors with `server exited 1: ... No such file or directory ... server.rb`

- [ ] **Step 3: Write the implementation**

`mcp/file-to-s3/server.rb`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

# Local stdio MCP server that uploads files to file_to_s3 (files.chiq.me).
# Ruby stdlib only, so it runs on any machine with Ruby 3 — including over SSH.
# Login: the server posts a one-time code to Slack #otp, the user reads it to
# Claude, and the code is exchanged for a token that never expires.

require "fileutils"
require "json"
require "net/http"
require "openssl"
require "socket"
require "uri"

module FileToS3Mcp
  PROTOCOL_VERSION = "2025-06-18"
  NOT_LOGGED_IN = "Not logged in to file_to_s3. Call file_to_s3_login, ask the user for the " \
                  "6-digit code posted to Slack #otp, then call file_to_s3_verify with it."

  TOOLS = [
    {
      name: "file_to_s3_login",
      description: "Start logging in to file_to_s3: posts a 6-digit one-time code to the user's " \
                   "Slack #otp channel. Then ask the user for the code and call file_to_s3_verify.",
      inputSchema: { type: "object", properties: {} }
    },
    {
      name: "file_to_s3_verify",
      description: "Finish logging in to file_to_s3 with the 6-digit code the user read from " \
                   "Slack #otp. Saves a token on this machine that never expires.",
      inputSchema: {
        type: "object",
        properties: { code: { type: "string", description: "The 6-digit code from Slack #otp" } },
        required: ["code"]
      }
    },
    {
      name: "upload_file",
      description: "Upload a local file (max 25 MB) to file_to_s3 and return its public URL. " \
                   "Without name the URL is unique (UUID-prefixed). With name the file is stored " \
                   "as exactly that name, overwriting the previous upload, so the URL is stable: " \
                   "https://files.chiq.me/files/<name>.",
      inputSchema: {
        type: "object",
        properties: {
          path: { type: "string", description: "Absolute or ~/ path to the local file" },
          name: { type: "string", description: "Optional stable filename (e.g. app-manifest.plist). " \
                                                "Re-uploading with the same name replaces the file " \
                                                "and keeps the same URL." }
        },
        required: ["path"]
      }
    }
  ].freeze

  class ToolError < StandardError; end

  # Talks HTTP to the file_to_s3 app and owns the saved token.
  class Client
    def initialize(base_url:, token_file:)
      @base_url = base_url.chomp("/")
      @token_file = token_file
    end

    def request_otp
      response = post("/auth/otp", form: { "label" => Socket.gethostname })
      raise ToolError, "file_to_s3 refused the login (#{response.code}): #{response.body}" unless response.code == "202"

      "A 6-digit code was posted to Slack #otp. Ask the user for it, then call file_to_s3_verify with the code."
    end

    def verify(code)
      response = post("/auth/verify", form: { "code" => code.to_s.strip, "label" => Socket.gethostname })
      unless response.code == "200"
        raise ToolError, "Code rejected (#{response.code}): #{response.body}. " \
                         "If it expired, call file_to_s3_login for a new one."
      end

      save_token(JSON.parse(response.body).fetch("token"))
      "Logged in to file_to_s3 as #{Socket.gethostname}. The token never expires."
    end

    def upload(path, name = nil)
      token = read_token or raise ToolError, NOT_LOGGED_IN
      full_path = File.expand_path(path.to_s)
      raise ToolError, "Not a readable file: #{full_path}" unless File.file?(full_path) && File.readable?(full_path)

      query = name.to_s.strip.empty? ? "" : "?#{URI.encode_www_form(name: name.strip)}"
      response = File.open(full_path, "rb") do |file|
        post("/upload#{query}", multipart: [["file", file, { filename: File.basename(full_path) }]], token: token)
      end

      case response.code
      when "200" then response.body.strip
      when "401" then raise ToolError, NOT_LOGGED_IN
      else raise ToolError, "Upload failed (#{response.code}): #{response.body}"
      end
    end

    private

    def post(path, form: nil, multipart: nil, token: nil)
      uri = URI("#{@base_url}#{path}")
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{token}" if token
      multipart ? request.set_form(multipart, "multipart/form-data") : request.set_form_data(form)

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 300) do |http|
        http.request(request)
      end
    rescue SocketError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError => e
      raise ToolError, "Could not reach #{@base_url}: #{e.message}"
    end

    def read_token
      return nil unless File.exist?(@token_file)

      token = File.read(@token_file).strip
      token.empty? ? nil : token
    end

    def save_token(token)
      FileUtils.mkdir_p(File.dirname(@token_file), mode: 0o700)
      File.write(@token_file, token, perm: 0o600)
      File.chmod(0o600, @token_file) # perm: only applies when the file is created
    end
  end

  # Newline-delimited JSON-RPC 2.0 over stdio. Only stdout carries protocol
  # messages; anything diagnostic goes to stderr.
  class Server
    def initialize(client, input: $stdin, output: $stdout)
      @client = client
      @input = input
      @output = output
    end

    def run
      @output.sync = true
      @input.each_line do |line|
        next if line.strip.empty?

        response = handle_line(line)
        @output.puts(JSON.generate(response)) if response
      end
    end

    private

    def handle_line(line)
      handle(JSON.parse(line))
    rescue JSON::ParserError
      error(nil, -32700, "Parse error")
    rescue StandardError => e
      warn "[file-to-s3] #{e.class}: #{e.message}"
      error(nil, -32603, e.message)
    end

    def handle(message)
      return nil unless message.key?("id") # notifications get no reply

      id = message["id"]
      result =
        case message["method"]
        when "initialize" then initialize_result(message["params"] || {})
        when "ping" then {}
        when "tools/list" then { tools: TOOLS }
        when "tools/call" then call_tool(message.dig("params", "name"), message.dig("params", "arguments") || {})
        else return error(id, -32601, "Method not found: #{message["method"]}")
        end
      { jsonrpc: "2.0", id: id, result: result }
    end

    def initialize_result(params)
      {
        protocolVersion: params["protocolVersion"] || PROTOCOL_VERSION,
        capabilities: { tools: {} },
        serverInfo: { name: "file-to-s3", version: "1.0.0" }
      }
    end

    def call_tool(name, arguments)
      text =
        case name
        when "file_to_s3_login" then @client.request_otp
        when "file_to_s3_verify" then @client.verify(arguments["code"])
        when "upload_file" then @client.upload(arguments["path"], arguments["name"])
        else raise ToolError, "Unknown tool: #{name}"
        end
      { content: [{ type: "text", text: text }], isError: false }
    rescue ToolError => e
      { content: [{ type: "text", text: e.message }], isError: true }
    end

    def error(id, code, message)
      { jsonrpc: "2.0", id: id, error: { code: code, message: message } }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  client = FileToS3Mcp::Client.new(
    base_url: ENV.fetch("FILE_TO_S3_URL", "https://files.chiq.me"),
    token_file: ENV.fetch("FILE_TO_S3_TOKEN_FILE") { File.expand_path("~/.config/file-to-s3/token") }
  )
  FileToS3Mcp::Server.new(client).run
end
```

Then: `chmod +x /Users/grillermo/c/agents-configs/mcp/file-to-s3/server.rb`

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/grillermo/c/agents-configs && ruby tests/file-to-s3-mcp.test.rb`
Expected: `17 runs, ... 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
cd /Users/grillermo/c/agents-configs
git add mcp/file-to-s3/server.rb tests/file-to-s3-mcp.test.rb
git commit -m "feat: add file-to-s3 stdio MCP with Slack OTP login

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Register the MCP from `install.sh`

**Files:**
- Modify: `/Users/grillermo/c/agents-configs/install.sh` (header comment; new `register_mcp` function before the `echo "installing into ..."` block; call it after `register_statusline`)
- Modify: `/Users/grillermo/c/agents-configs/tests/install.test.sh` (fake `claude` on PATH for every run; new cases before the final `printf 'ok\n'`)

**Interfaces:**
- Consumes: `mcp/file-to-s3/server.rb` (Task 6) path.
- Produces: `CLAUDE_BIN` env override (default `claude`); output lines `mcp: file-to-s3 registered` / `mcp: file-to-s3 already registered` / `mcp: skipped (claude not installed)`.

- [ ] **Step 1: Write the failing test**

In `tests/install.test.sh`, replace the existing `run()` function with the block below. Every run gets a fake `claude`, so the real CLI is never touched:

```sh
# A stand-in claude CLI: logs each call into the fake HOME and remembers a
# registration, so `mcp get` answers like the real one after `mcp add`.
fakebin="$work/bin"
mkdir -p "$fakebin"
cat >"$fakebin/claude" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$HOME/claude-calls.log"
case "$1 $2" in
  "mcp get") [ -e "$HOME/mcp-registered" ] ;;
  "mcp add") : >"$HOME/mcp-registered" ;;
esac
EOF
chmod +x "$fakebin/claude"

# The install dir is hardcoded to $HOME/.claude, so a fake HOME is what isolates
# a test run. CLAUDE_CONFIG_DIR is set here too, to prove it is ignored.
run() {
  HOME="$1" CLAUDE_CONFIG_DIR="$work/ignored" PATH="$fakebin:$PATH" "$SCRIPT"
}
```

(Delete the old two-line comment above the original `run()` since the new block carries it.)

Directly before the final `printf 'ok\n'`, add:

```sh
# The file-to-s3 MCP is registered at user scope, exactly once.
mcphome="$work/mcphome"
mkdir -p "$mcphome"
output=$(run "$mcphome")
assert_contains "mcp: file-to-s3 registered" "$output"
assert_contains "mcp add --scope user file-to-s3 -- ruby $ROOT_DIR/mcp/file-to-s3/server.rb" "$(cat "$mcphome/claude-calls.log")"
output=$(run "$mcphome")
assert_contains "mcp: file-to-s3 already registered" "$output"
[ "$(grep -c 'mcp add' "$mcphome/claude-calls.log")" = 1 ] || fail "expected exactly one mcp add"

# Without the claude CLI the step is skipped, not fatal.
noclaude="$work/noclaude"
mkdir -p "$noclaude"
output=$(HOME="$noclaude" CLAUDE_BIN="$work/missing-claude" "$SCRIPT")
assert_contains "mcp: skipped (claude not installed)" "$output"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/grillermo/c/agents-configs && sh tests/install.test.sh`
Expected: FAIL — `expected output to contain mcp: file-to-s3 registered`

- [ ] **Step 3: Write the implementation**

In `install.sh`, extend the header comment's first sentence to mention the MCP:

```bash
# Symlink this repo's skills/, rules/ and statusline script into ~/.claude so a
# fresh machine picks them up, register the status line in settings.json, and
# register the file-to-s3 MCP with the claude CLI.
```

Add before `echo "installing into $claude_dir"`:

```bash
# User scope, so every project on this machine gets it. The command points at
# this checkout: moving the repo means `claude mcp remove file-to-s3 -s user`
# and re-running this script. CLAUDE_BIN exists for the tests.
register_mcp() {
  local claude_bin=${CLAUDE_BIN:-claude}

  if ! command -v "$claude_bin" >/dev/null 2>&1; then
    echo "mcp: skipped (claude not installed)"
    return 0
  fi

  if "$claude_bin" mcp get file-to-s3 >/dev/null 2>&1; then
    echo "mcp: file-to-s3 already registered"
    return 0
  fi

  "$claude_bin" mcp add --scope user file-to-s3 -- ruby "$repo_root/mcp/file-to-s3/server.rb" >/dev/null
  echo "mcp: file-to-s3 registered"
}
```

After the `register_statusline` call at the bottom, add:

```bash
register_mcp
```

- [ ] **Step 4: Run all agents-configs tests to verify they pass**

Run: `cd /Users/grillermo/c/agents-configs && sh tests/install.test.sh && sh tests/upload-shortcut.test.sh && sh tests/serve-shortcut.test.sh && ruby tests/file-to-s3-mcp.test.rb`
Expected: `ok` from each shell test, then `17 runs, ... 0 failures, 0 errors`.

- [ ] **Step 5: Commit**

```bash
cd /Users/grillermo/c/agents-configs
git add install.sh tests/install.test.sh
git commit -m "feat: register file-to-s3 MCP from install.sh

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Local end-to-end check (with the user)

No new code. Requires the user because the OTP arrives in their Slack.

- [ ] **Step 1: Start the app locally** (uses the real `SLACK_OTP_WEBHOOK_URL` from `.env`; a scratch tokens file keeps the repo clean)

Run (background): `cd /Users/grillermo/c/file_to_s3 && TOKENS_FILE=$TMPDIR/fts-e2e-tokens.json FILES_DIR=$TMPDIR/fts-e2e-files bin/rackup -s webrick`

- [ ] **Step 2: Drive the MCP against it**

```sh
cd /Users/grillermo/c/agents-configs
export FILE_TO_S3_URL=http://localhost:33333 FILE_TO_S3_TOKEN_FILE=$TMPDIR/fts-e2e-token
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"file_to_s3_login","arguments":{}}}' | ruby mcp/file-to-s3/server.rb
```

Expected: `isError:false`. Ask the user for the code they received in Slack #otp, then:

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"file_to_s3_verify","arguments":{"code":"<CODE>"}}}' | ruby mcp/file-to-s3/server.rb
echo hello > $TMPDIR/fts-e2e.txt
printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"upload_file\",\"arguments\":{\"path\":\"$TMPDIR/fts-e2e.txt\"}}}" | ruby mcp/file-to-s3/server.rb
```

Expected: verify → "Logged in…"; upload → a `http://localhost:33333/files/<uuid>-fts-e2e.txt` URL; `curl` of it prints `hello`.

- [ ] **Step 3: Revoke and confirm**

Run: `cd /Users/grillermo/c/file_to_s3 && TOKENS_FILE=$TMPDIR/fts-e2e-tokens.json bin/tokens revoke "$(hostname | tr -cd 'A-Za-z0-9_.-' | cut -c1-64)"` then repeat the upload call.
Expected: `revoked 1`; upload → `isError:true` with "Not logged in…".

- [ ] **Step 4: Clean up** — stop the rackup process; `rm -rf $TMPDIR/fts-e2e*`.

- [ ] **Step 5: Hand off deploy to the user** — they deploy `file_to_s3` to files.chiq.me, add `SLACK_OTP_WEBHOOK_URL` to the server's `.env` (same value as local; do not print it), restart, push `agents-configs`, and run `./install.sh` on each machine.
