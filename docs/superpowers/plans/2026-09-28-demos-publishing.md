# demos.grillermo.com Publishing Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve only hand-picked files on demos.grillermo.com, while files.chiq.me keeps serving everything.

**Architecture:** Publishing copies a file from `files/` into a separate `demos/` directory. A second, tiny Rack process (`demos.ru` → `DemoApp`, port 33334, bound to 127.0.0.1) serves only `demos/` and loads none of the main app. The toggle lives on `files.chiq.me/index`, behind a signed-cookie session obtained through the existing Slack OTP. `./serve` runs both processes as panes of one tmux session.

**Tech Stack:** Ruby, Rack 3, WEBrick, Minitest + Rack::MockRequest, bash + tmux.

**Spec:** `docs/superpowers/specs/2026-09-28-demos-publishing-design.md`

**Running tests:** the Gemfile pins Ruby 3.2.4, which isn't installed on the dev machine, so `bundle exec` fails there. Run tests without Bundler:
- one file: `ruby -Itest test/<name>_test.rb`
- everything: `for f in test/*_test.rb; do ruby -Itest "$f" | tail -1; done`

---

## File map

| File | Status | Responsibility |
|---|---|---|
| `lib/file_body.rb` | create | `FileBody` streaming body + `FileBody.headers(path)`; shared by both apps |
| `lib/session.rb` | create | Stateless signed login cookie (`issue`, `valid?`, `configured?`) |
| `lib/publisher.rb` | create | Copy into / delete from `demos/`; `published?` |
| `lib/demo_app.rb` | create | Public app: GET/HEAD a file from `demos/`, 404 for everything else |
| `demos.ru` | create | Rackup file for the demos process |
| `app.rb` | modify | Use shared `FileBody`; `/login`, `/auth/session`, `/logout`, `/publish`, `/unpublish`; toggle on `/index` |
| `serve` | rewrite | tmux session `file_server` with `files` and `demos` panes |
| `test/file_body_test.rb`, `test/session_test.rb`, `test/publisher_test.rb`, `test/publishing_test.rb`, `test/demo_app_test.rb` | create | Tests |
| `.gitignore`, `.env.example`, `README.md` | modify | `demos/`, new env vars, docs |

---

## Chunk 1: Shared building blocks

### Task 1: Extract `FileBody` into `lib/file_body.rb`

**Files:**
- Create: `lib/file_body.rb`
- Modify: `app.rb` (remove the nested `FileBody` class, lines ~16-35; simplify `serve_file`)
- Test: `test/file_body_test.rb`

- [ ] **Step 1: Write the failing test**

`test/file_body_test.rb`:

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/file_body"

class FileBodyTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("file_server-body-")
    @path = File.join(@dir, "page.html")
    File.write(@path, "<h1>hi</h1>")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_headers_carry_type_and_length
    assert_equal({ "content-type" => "text/html", "content-length" => "11" }, FileBody.headers(@path))
  end

  def test_unknown_extensions_are_octet_stream
    path = File.join(@dir, "blob.zzz")
    File.write(path, "x")

    assert_equal "application/octet-stream", FileBody.headers(path)["content-type"]
  end

  def test_body_streams_the_file
    body = FileBody.new(@path)
    chunks = []
    body.each { |chunk| chunks << chunk }

    assert_equal @path, body.to_path
    assert_equal "<h1>hi</h1>", chunks.join
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `ruby -Itest test/file_body_test.rb`
Expected: `cannot load such file -- .../lib/file_body` (LoadError)

- [ ] **Step 3: Create `lib/file_body.rb`**

```ruby
# frozen_string_literal: true

require "rack/mime"

# Streams a stored file instead of reading it into memory. WEBrick sends
# anything with to_path straight from disk; other servers use each. Lives on
# its own so the demos app can serve files without loading the main app.
class FileBody
  CHUNK_SIZE = 64 * 1024

  def self.headers(path)
    {
      "content-type" => Rack::Mime.mime_type(File.extname(path), "application/octet-stream"),
      "content-length" => File.size(path).to_s
    }
  end

  def initialize(path)
    @path = path
  end

  def to_path
    @path
  end

  def each
    File.open(@path, "rb") do |file|
      while (chunk = file.read(CHUNK_SIZE))
        yield chunk
      end
    end
  end
end
```

- [ ] **Step 4: Make `app.rb` use it**

In `app.rb`:
1. Add `require_relative "lib/file_body"` next to the other `require_relative` lines.
2. Delete the nested class, meaning the comment "Streams a stored file instead of reading it into memory…" and the whole `class FileBody … end` block inside `FileServerApp`.
3. Replace the body of `serve_file` after the `File.file?` guard with:

```ruby
    return not_found unless File.file?(path)

    headers = FileBody.headers(path)
    return [200, headers, []] if head

    [200, headers, FileBody.new(path)]
```

- [ ] **Step 5: Run the new test and the whole suite**

Run: `for f in test/*_test.rb; do ruby -Itest "$f" | tail -1; done`
Expected: every line ends in `0 failures, 0 errors`.

- [ ] **Step 6: Commit**

```bash
git add lib/file_body.rb app.rb test/file_body_test.rb
git commit -m "refactor: extract FileBody into lib/file_body.rb"
```

### Task 2: `Session` (signed login cookie)

**Files:**
- Create: `lib/session.rb`
- Test: `test/session_test.rb`

- [ ] **Step 1: Write the failing test**

`test/session_test.rb`:

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/session"

class SessionTest < Minitest::Test
  def setup
    @now = Time.at(1_000_000)
    @session = Session.new(secret: "s" * 64, clock: -> { @now })
  end

  def test_an_issued_value_is_valid
    assert @session.valid?(@session.issue)
  end

  def test_expires_after_the_ttl
    value = @session.issue
    @now += Session::TTL

    refute @session.valid?(value)
  end

  def test_a_tampered_expiry_is_rejected
    expires_at, mac = @session.issue.split(".")

    refute @session.valid?("#{expires_at.to_i + 1}.#{mac}")
  end

  def test_a_value_signed_with_another_secret_is_rejected
    other = Session.new(secret: "t" * 64, clock: -> { @now })

    refute @session.valid?(other.issue)
  end

  def test_garbage_is_rejected
    [nil, "", "abc", "123", "123.", ".abc", "x.y"].each do |value|
      refute @session.valid?(value), value.inspect
    end
  end

  def test_without_a_secret_nothing_is_valid_and_nothing_is_issued
    session = Session.new(secret: "")

    refute session.configured?
    refute session.valid?(@session.issue)
    assert_raises(RuntimeError) { session.issue }
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `ruby -Itest test/session_test.rb`
Expected: LoadError for `lib/session`.

- [ ] **Step 3: Create `lib/session.rb`**

```ruby
# frozen_string_literal: true

require "openssl"
require "rack/utils"

# Browser login for the publish toggle. The cookie value is
# "<expires_at>.<hmac>" signed with SESSION_SECRET, so nothing is stored
# server-side; changing the secret logs every browser out.
class Session
  COOKIE = "fs_session"
  TTL = 30 * 24 * 60 * 60

  def self.from_env
    new(secret: ENV["SESSION_SECRET"])
  end

  def initialize(secret:, clock: -> { Time.now })
    @secret = secret.to_s.empty? ? nil : secret
    @clock = clock
  end

  def configured?
    !@secret.nil?
  end

  def issue
    raise "SESSION_SECRET not configured" unless configured?

    expires_at = (@clock.call.to_i + TTL).to_s
    "#{expires_at}.#{sign(expires_at)}"
  end

  def valid?(value)
    return false unless configured?

    expires_at, mac = value.to_s.split(".", 2)
    return false unless expires_at&.match?(/\A\d+\z/) && mac

    Rack::Utils.secure_compare(sign(expires_at), mac) && expires_at.to_i > @clock.call.to_i
  end

  private

  def sign(data)
    OpenSSL::HMAC.hexdigest("SHA256", @secret, data)
  end
end
```

- [ ] **Step 4: Run it**

Run: `ruby -Itest test/session_test.rb`
Expected: `6 runs, … 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
git add lib/session.rb test/session_test.rb
git commit -m "feat: signed stateless login session"
```

### Task 3: `Publisher` (copy into / remove from `demos/`)

**Files:**
- Create: `lib/publisher.rb`
- Test: `test/publisher_test.rb`

- [ ] **Step 1: Write the failing test**

`test/publisher_test.rb`:

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "../lib/publisher"

class PublisherTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("file_server-publisher-")
    @files = File.join(@dir, "files")
    @demos = File.join(@dir, "demos")
    FileUtils.mkdir_p(@files)
    @publisher = Publisher.new(files_dir: @files, demos_dir: @demos)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def stored(name, content)
    File.write(File.join(@files, name), content)
  end

  def test_publish_copies_the_file_into_demos
    stored("demo.html", "v1")
    @publisher.publish("demo.html")

    assert_equal "v1", File.read(File.join(@demos, "demo.html"))
    assert @publisher.published?("demo.html")
  end

  def test_the_copy_is_a_real_file_not_a_link
    stored("demo.html", "v1")
    @publisher.publish("demo.html")
    copy = File.join(@demos, "demo.html")

    refute File.symlink?(copy)
    refute_equal File.stat(File.join(@files, "demo.html")).ino, File.stat(copy).ino
  end

  def test_overwriting_the_original_leaves_the_copy_alone
    stored("demo.html", "v1")
    @publisher.publish("demo.html")
    stored("demo.html", "v2")

    assert_equal "v1", File.read(File.join(@demos, "demo.html"))
  end

  def test_republishing_refreshes_the_copy_and_leaves_no_temp_files
    stored("demo.html", "v1")
    @publisher.publish("demo.html")
    stored("demo.html", "v2")
    @publisher.publish("demo.html")

    assert_equal "v2", File.read(File.join(@demos, "demo.html"))
    assert_equal ["demo.html"], Dir.children(@demos)
  end

  def test_unpublish_removes_only_the_copy
    stored("demo.html", "v1")
    @publisher.publish("demo.html")
    @publisher.unpublish("demo.html")

    refute @publisher.published?("demo.html")
    assert File.file?(File.join(@files, "demo.html"))
  end

  def test_unpublishing_something_unpublished_is_a_no_op
    @publisher.unpublish("nothing.html")
    @publisher.unpublish("")

    refute File.exist?(@demos) && !Dir.empty?(@demos)
  end

  def test_publishing_a_missing_file_raises
    assert_raises(Publisher::NotFound) { @publisher.publish("missing.html") }
    assert_raises(Publisher::NotFound) { @publisher.publish("") }
  end

  def test_names_cannot_escape_either_directory
    File.write(File.join(@dir, "secret.txt"), "secret")

    assert_raises(Publisher::NotFound) { @publisher.publish("../secret.txt") }
    refute File.exist?(File.join(@demos, "secret.txt"))
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `ruby -Itest test/publisher_test.rb`
Expected: LoadError for `lib/publisher`.

- [ ] **Step 3: Create `lib/publisher.rb`**

```ruby
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
```

- [ ] **Step 4: Run it**

Run: `ruby -Itest test/publisher_test.rb`
Expected: `8 runs, … 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
git add lib/publisher.rb test/publisher_test.rb
git commit -m "feat: publisher copies files into demos dir"
```

---

## Chunk 2: The demos process

### Task 4: `DemoApp` + `demos.ru`

**Files:**
- Create: `lib/demo_app.rb`, `demos.ru`
- Test: `test/demo_app_test.rb`

- [ ] **Step 1: Write the failing test**

`test/demo_app_test.rb`:

```ruby
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
```

- [ ] **Step 2: Run it and watch it fail**

Run: `ruby -Itest test/demo_app_test.rb`
Expected: LoadError for `lib/demo_app`.

- [ ] **Step 3: Create `lib/demo_app.rb`**

```ruby
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
```

- [ ] **Step 4: Create `demos.ru`**

```ruby
require_relative "lib/demo_app"

Process.setproctitle("file_server-demos")
run DemoApp.new
```

- [ ] **Step 5: Run it**

Run: `ruby -Itest test/demo_app_test.rb`
Expected: `7 runs, … 0 failures, 0 errors`

- [ ] **Step 6: Commit**

```bash
git add lib/demo_app.rb demos.ru test/demo_app_test.rb
git commit -m "feat: demos app serving only the demos dir"
```

---

## Chunk 3: Login and publishing in the main app

All of Chunk 3 is tested in one new file, `test/publishing_test.rb`, which each task adds to.

### Task 5: `/login`, `/auth/session`, `/logout`

**Files:**
- Modify: `app.rb`
- Test: `test/publishing_test.rb` (create)

- [ ] **Step 1: Write the failing test**

`test/publishing_test.rb`:

```ruby
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
    request("POST", "/auth/otp", "label" => "browser")
    status, headers, = request("POST", "/auth/session", "code" => @sent.last[/\d{6}/])
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
    request("POST", "/auth/otp", "label" => "browser")
    status, headers, = request("POST", "/auth/session", "code" => @sent.last[/\d{6}/])
    cookie = headers["set-cookie"].downcase

    assert_equal 303, status
    assert_equal "/index", headers["location"]
    %w[httponly secure samesite=strict path=/].each { |flag| assert_includes cookie, flag }
    assert @session.valid?(headers["set-cookie"][/#{Session::COOKIE}=([^;]+)/o, 1])
  end

  def test_a_wrong_code_sets_no_cookie
    request("POST", "/auth/otp", "label" => "browser")
    status, headers, = request("POST", "/auth/session", "code" => "000000")

    assert_equal 401, status
    assert_nil headers["set-cookie"]
  end

  def test_login_without_a_session_secret_is_refused_before_using_the_code
    app = FileServerApp.new(otp: @otp, tokens: TokenStore.new(File.join(@dir, "tokens.json")),
                            session: Session.new(secret: nil))
    request("POST", "/auth/otp", "label" => "browser")
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
```

- [ ] **Step 2: Run it and watch it fail**

Run: `ruby -Itest test/publishing_test.rb`
Expected: errors, starting with `ArgumentError: unknown keyword: :session`

- [ ] **Step 3: Wire `Session` into `app.rb`**

1. Add `require_relative "lib/session"` and `require_relative "lib/publisher"` next to the other requires.
2. Change `initialize` to:

```ruby
  def initialize(otp: Otp.new(notifier: SlackNotifier.from_env),
                 tokens: TokenStore.new(ENV.fetch("TOKENS_FILE") { File.join(__dir__, "tokens.json") }),
                 session: Session.from_env)
    @otp = otp
    @tokens = tokens
    @session = session
  end
```

3. In `call`, add these routes before `in ["GET", "/health"]`:

```ruby
    in ["GET", "/login"]
      serve_login
    in ["POST", "/auth/session"]
      start_session(req)
    in ["POST", "/logout"]
      end_session
```

4. Add these private methods after `otp_label`:

```ruby
  # The browser session only unlocks the publish toggle; uploads still need a
  # bearer token.
  def logged_in?(req)
    @session.valid?(req.cookies[Session::COOKIE])
  end

  # Checked before the code is spent, so a missing SESSION_SECRET doesn't burn it.
  def start_session(req)
    return text_response(503, "SESSION_SECRET not configured") unless @session.configured?
    return text_response(401, "Invalid or expired code") unless @otp.verify(req.params["code"].to_s.strip)

    cookie = Rack::Utils.set_cookie_header(
      Session::COOKIE,
      value: @session.issue, path: "/", max_age: Session::TTL,
      httponly: true, secure: true, same_site: :strict
    )
    redirect("/index", "set-cookie" => cookie)
  end

  def end_session
    redirect("/index", "set-cookie" => Rack::Utils.delete_set_cookie_header(Session::COOKIE, path: "/"))
  end

  def redirect(location, extra_headers = {})
    [303, { "location" => location }.merge(extra_headers), []]
  end

  def serve_login
    html = <<~HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Log in</title>
      <style>#{listing_css}</style>
      </head>
      <body>
      <header><h1>Log in</h1><p class="count" id="status">A code will be posted to Slack #otp.</p></header>
      <main class="login">
      <button type="button" id="send">Send code</button>
      <form method="post" action="/auth/session">
      <input name="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" required placeholder="123456">
      <button>Log in</button>
      </form>
      </main>
      <script>
      document.getElementById("send").addEventListener("click", async () => {
        const res = await fetch("/auth/otp", { method: "POST", body: new URLSearchParams({ label: "browser" }) });
        document.getElementById("status").textContent = await res.text();
      });
      </script>
      </body>
      </html>
    HTML
    [200, { "content-type" => "text/html; charset=utf-8", "cache-control" => "no-store" }, [html]]
  end
```

5. At the end of the `listing_css` heredoc (just before the `@media` line), add:

```css
      button { font: inherit; font-size: .8rem; padding: .3rem .7rem; border: 1px solid var(--line);
               border-radius: 8px; background: var(--card); color: inherit; }
      .auth { float: right; margin: .3rem 0 0; font-size: .85rem; color: var(--accent); }
      .login { max-width: 46rem; margin: 0 auto; display: grid; gap: .75rem; justify-items: start; }
      .login form { display: flex; gap: .5rem; }
      .login input { font: inherit; padding: .4rem .7rem; border: 1px solid var(--line); border-radius: 8px;
                     background: var(--card); color: inherit; }
```

- [ ] **Step 4: Run the new file and the whole suite**

Run: `for f in test/*_test.rb; do ruby -Itest "$f" | tail -1; done`
Expected: every line ends in `0 failures, 0 errors`.

- [ ] **Step 5: Commit**

```bash
git add app.rb test/publishing_test.rb
git commit -m "feat: browser login via Slack OTP session cookie"
```

### Task 6: `POST /publish` and `POST /unpublish`

**Files:**
- Modify: `app.rb`
- Test: `test/publishing_test.rb`

- [ ] **Step 1: Add the failing tests**

Append to `PublishingTest`:

```ruby
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

    assert_equal 401, request("POST", "/unpublish", "name" => "demo.html").first
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
```

- [ ] **Step 2: Run them and watch them fail**

Run: `ruby -Itest test/publishing_test.rb`
Expected: the new publish tests fail with 404 (the route doesn't exist yet).

- [ ] **Step 3: Add the routes and handler**

In `call`, add after the `/logout` route:

```ruby
    in ["POST", ("/publish" | "/unpublish") => action]
      return unauthorized unless logged_in?(req) || authenticated?(req)

      toggle_publish(req, action)
```

Add these private methods after `end_session`/`redirect`:

```ruby
  # Copies into (or deletes from) demos/, which the separate demos process
  # serves. Dotfiles are refused because the demos app never serves them.
  def toggle_publish(req, action)
    name = File.basename(req.params["name"].to_s)
    return unprocessable("#{name} can't be published") unless publishable?(name)

    action == "/publish" ? publisher.publish(name) : publisher.unpublish(name)
    redirect("/index")
  rescue Publisher::NotFound
    not_found
  end

  def publishable?(name)
    !name.empty? && !name.start_with?(".") && !RESERVED_NAMES.include?(name.downcase)
  end

  def publisher
    Publisher.new(files_dir: files_dir, demos_dir: demos_dir)
  end

  # Overridable like files_dir. Must match the demos process's DEMOS_DIR.
  def demos_dir
    ENV.fetch("DEMOS_DIR") { File.join(__dir__, "demos") }
  end
```

- [ ] **Step 4: Run the suite**

Run: `for f in test/*_test.rb; do ruby -Itest "$f" | tail -1; done`
Expected: every line ends in `0 failures, 0 errors`.

- [ ] **Step 5: Commit**

```bash
git add app.rb test/publishing_test.rb
git commit -m "feat: publish/unpublish endpoints"
```

### Task 7: Toggle on `/index`

**Files:**
- Modify: `app.rb` (`serve_listing`, `listing_row`, `listing_css`)
- Test: `test/publishing_test.rb`

- [ ] **Step 1: Add the failing tests**

Append to `PublishingTest`:

```ruby
  # --- listing ---------------------------------------------------------

  def test_listing_logged_out_offers_login_and_no_toggle
    stored("demo.html", "v1")
    html = body_of(request("GET", "/index")[2])

    assert_includes html, %(href="/login")
    refute_includes html, "/publish"
  end

  def test_listing_logged_in_offers_publish_and_logout
    stored("demo.html", "v1")
    html = body_of(request("GET", "/index", cookie: @session.issue)[2])

    assert_includes html, %(action="/publish")
    assert_includes html, %(name="name" value="demo.html")
    assert_includes html, %(action="/logout")
    refute_includes html, "demos.grillermo.com"
  end

  def test_listing_shows_the_demo_url_and_unpublish_for_published_files
    stored("demo.html", "v1")
    request("POST", "/publish", { "name" => "demo.html" }, token: "test-token")
    html = body_of(request("GET", "/index", cookie: @session.issue)[2])

    assert_includes html, %(action="/unpublish")
    assert_includes html, %(href="https://demos.grillermo.com/demo.html")
  end

  def test_demos_url_is_configurable
    ENV["DEMOS_URL"] = "https://demos.example/"
    stored("demo.html", "v1")
    request("POST", "/publish", { "name" => "demo.html" }, token: "test-token")
    html = body_of(request("GET", "/index", cookie: @session.issue)[2])

    assert_includes html, %(href="https://demos.example/demo.html")
  ensure
    ENV.delete("DEMOS_URL")
  end

  def test_reserved_files_get_no_toggle
    stored("mcp.html", "x")
    html = body_of(request("GET", "/index", cookie: @session.issue)[2])

    refute_includes html, %(value="mcp.html")
  end
```

- [ ] **Step 2: Run them and watch them fail**

Run: `ruby -Itest test/publishing_test.rb`
Expected: the five listing tests fail (no login link / no forms).

- [ ] **Step 3: Update the listing**

In `serve_listing(req)`:
- compute `logged_in = logged_in?(req)` at the top
- pass it on: `listing_row(req, name, size, mtime, logged_in)`
- change the header line to:

```ruby
      <header>#{auth_control(logged_in)}<h1>Files</h1><p class="count">#{entries.size} #{entries.size == 1 ? "file" : "files"}</p></header>
```

Change `listing_row`'s signature to `def listing_row(req, name, size, mtime, logged_in)` and its `ROW` heredoc to:

```ruby
    <<~ROW
      <li><a href="#{escape_html(file_url(req, name))}">
      <span class="name">#{label}</span>
      <span class="meta">#{human_size(size)} &middot; #{mtime.strftime("%Y-%m-%d %H:%M")}</span>
      </a>#{publish_controls(name) if logged_in && publishable?(name)}</li>
    ROW
```

Add these private methods next to `listing_row`:

```ruby
  def auth_control(logged_in)
    return %(<a class="auth" href="/login">Log in</a>) unless logged_in

    %(<form class="auth" method="post" action="/logout"><button>Log out</button></form>)
  end

  # A form beside the row's link (a form can't sit inside an <a>). Posts to
  # /publish or /unpublish, which redirect back here.
  def publish_controls(name)
    if publisher.published?(name)
      url = escape_html(demo_url(name))
      action, label, link = "/unpublish", "Public — unpublish", %(<a class="demo" href="#{url}">#{url}</a>)
    else
      action, label, link = "/publish", "Make public", ""
    end

    <<~FORM
      <form class="publish" method="post" action="#{action}">
      <input type="hidden" name="name" value="#{escape_html(name)}">
      <button>#{label}</button>#{link}
      </form>
    FORM
  end

  def demo_url(name)
    base = ENV.fetch("DEMOS_URL", "https://demos.grillermo.com").chomp("/")
    "#{base}/#{URI::DEFAULT_PARSER.escape(name)}"
  end
```

Add to `listing_css`, next to the rules from Task 5:

```css
      form.publish { display: flex; flex-wrap: wrap; gap: .5rem; align-items: center; margin: 0; padding: 0 1rem .8rem; }
      ul.files a.demo { display: inline; padding: 0; color: var(--accent); font-size: .8rem; overflow-wrap: anywhere; }
```

- [ ] **Step 4: Run the suite**

Run: `for f in test/*_test.rb; do ruby -Itest "$f" | tail -1; done`
Expected: every line ends in `0 failures, 0 errors` (the existing `test_index_*` tests in `app_test.rb` still pass because they run logged out).

- [ ] **Step 5: Commit**

```bash
git add app.rb test/publishing_test.rb
git commit -m "feat: publish toggle on the index when logged in"
```

---

## Chunk 4: Process management and docs

### Task 8: `./serve` runs both processes in tmux

**Files:**
- Rewrite: `serve`

This task has no Minitest coverage. It's verified with `shellcheck` and a real run.

- [ ] **Step 1: Replace `serve` with**

```bash
#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$APP_DIR"

set -a
# shellcheck source=/dev/null
[ -f .env ] && . ./.env
set +a

SESSION='file_server'
FILES_PORT="${PORT:-33333}"
DEMOS_PORT="${DEMO_PORT:-33334}"
export RACK_ENV="${RACK_ENV:-deployment}"

# One detached tmux session "file_server", two panes:
#   files : the full app (files.chiq.me + LAN) on $FILES_PORT
#   demos : demos.ru, only the published copies in demos/, on $DEMOS_PORT.
#           Bound to 127.0.0.1: the only way in is the demos.grillermo.com
#           tunnel route (cloudflared runs on this host).
# Re-running restarts both panes in place.
#
# tmux panes do NOT inherit this script's environment when a tmux server is
# already running, so every pane command re-sources .env and carries PATH.
ENV_SETUP="cd '$APP_DIR' && export PATH='$PATH' RACK_ENV='$RACK_ENV' && set -a && { [ ! -f .env ] || . ./.env; } && set +a"

files_cmd() {
  echo "$ENV_SETUP && exec bundle exec rackup config.ru -p $FILES_PORT -s webrick"
}

demos_cmd() {
  echo "$ENV_SETUP && exec bundle exec rackup demos.ru -o 127.0.0.1 -p $DEMOS_PORT -s webrick"
}

port_listeners() {
  lsof -ti "tcp:$1" -sTCP:LISTEN 2>/dev/null || true
}

# The previous occupant of our ports is always ours (including a foreground
# run of the old ./serve), so reclaim them before respawning a pane.
free_port() {
  local port="$1" pids
  pids=$(port_listeners "$port")
  [ -n "$pids" ] || return 0

  echo "==> Port $port still held by PID(s): $(echo "$pids" | tr '\n' ' ')- stopping"
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  for _ in $(seq 1 20); do
    sleep 0.5
    [ -n "$(port_listeners "$port")" ] || return 0
  done

  pids=$(port_listeners "$port")
  # shellcheck disable=SC2086
  [ -z "$pids" ] || kill -9 $pids 2>/dev/null || true
  sleep 1
  if [ -n "$(port_listeners "$port")" ]; then
    echo "ERROR: could not free port $port."
    return 1
  fi
}

# Guarded by has-session: under pipefail a missing session would otherwise
# abort the script on the very first run.
pane_for() {
  tmux has-session -t "=$SESSION" 2>/dev/null || return 0
  tmux list-panes -t "=$SESSION:" -F '#{pane_title} #{pane_id}' 2>/dev/null \
    | awk -v t="$1" '$1==t{print $2}'
}

pane_dead() {
  [ "$(tmux display-message -p -t "$1" '#{pane_dead}' 2>/dev/null)" = "1" ]
}

# remain-on-exit keeps a pane that crashed on boot around, holding its output.
start_pane() {
  local title="$1" cmd="$2" pid
  pid=$(pane_for "$title")

  if [ -z "$pid" ]; then
    if tmux has-session -t "=$SESSION" 2>/dev/null; then
      pid=$(tmux split-window -P -F '#{pane_id}' -t "=$SESSION:")
    else
      tmux new-session -d -s "$SESSION" -n main -x 200 -y 50
      pid=$(tmux list-panes -t "=$SESSION:" -F '#{pane_id}' | head -1)
    fi
    tmux select-pane -t "$pid" -T "$title"
  fi

  tmux set-option -t "=$SESSION:" remain-on-exit on >/dev/null
  tmux respawn-pane -k -t "$pid" "$cmd"
  # respawn-pane resets the title on some tmux versions.
  tmux select-pane -t "$pid" -T "$title"
  tmux select-layout -t "=$SESSION:" even-horizontal >/dev/null
}

dump_pane() {
  local pid
  pid=$(pane_for "$1")
  [ -n "$pid" ] || { echo "(no $1 pane to inspect)"; return 0; }
  echo "----- last lines of $1 pane -----"
  tmux capture-pane -p -S -500 -t "$pid" 2>/dev/null | grep -v '^$' | tail -n 25 || true
  echo "---------------------------------"
}

files_up() {
  local body
  body=$(curl -sf "http://127.0.0.1:$1/health" 2>/dev/null) || return 1
  [[ "$body" == *'"service":"chiq-file-server"'* ]]
}

http_status() {
  curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$1$2" 2>/dev/null || true
}

# The demos app has no health endpoint on purpose. A 404 for both / and
# /.probe (a dotfile, which it never serves, so no published file can collide)
# proves the port answers and that it isn't the full app, whose / answers 200.
demos_up() {
  [ "$(http_status "$1" /)" = "404" ] && [ "$(http_status "$1" /.probe)" = "404" ]
}

wait_for() {
  local title="$1" port="$2" check="$3" pid
  pid=$(pane_for "$title")
  echo "==> Waiting for $title on port $port..."
  for _ in $(seq 1 30); do
    if "$check" "$port"; then
      echo "==> $title up (port $port)"
      return 0
    fi
    if [ -z "$pid" ] || pane_dead "$pid"; then
      echo "ERROR: $title exited during boot."
      dump_pane "$title"
      return 1
    fi
    sleep 1
  done
  echo "ERROR: $title not up after 30s."
  dump_pane "$title"
  return 1
}

restart() {
  local title="$1" port="$2" cmd="$3" check="$4"
  echo "==> (Re)starting $title pane (port $port)"
  free_port "$port" || exit 1
  start_pane "$title" "$cmd"
  wait_for "$title" "$port" "$check" || exit 1
}

restart files "$FILES_PORT" "$(files_cmd)" files_up
restart demos "$DEMOS_PORT" "$(demos_cmd)" demos_up

echo "==> Session '$SESSION': files:$FILES_PORT, demos:$DEMOS_PORT"

if [ -n "${TMUX:-}" ]; then
  tmux switch-client -t "=$SESSION"
elif [ -t 1 ]; then
  echo "==> Attaching to '$SESSION' (detach with Ctrl-b d)"
  tmux attach-session -t "=$SESSION"
else
  echo "==> No TTY; not attaching. Run: tmux attach -t $SESSION"
fi
```

- [ ] **Step 2: Lint**

Run: `shellcheck serve`
Expected: no output (exit 0). Fix anything it reports.

- [ ] **Step 3: Real run (on the host that serves files.chiq.me)**

```bash
./serve
# from another terminal:
curl -s localhost:33333/health                         # {"service":"chiq-file-server"}
curl -s -o /dev/null -w '%{http_code}\n' localhost:33334/        # 404
curl -s -o /dev/null -w '%{http_code}\n' localhost:33334/.probe  # 404
./serve                                                 # re-run: both panes restart in place
```

Expected: both panes come up and the re-run succeeds. From another LAN machine, `curl <lan-ip>:33334/` fails to connect, because demos is bound to 127.0.0.1.

- [ ] **Step 4: Commit**

```bash
git add serve
git commit -m "feat: ./serve runs files and demos in tmux panes"
```

### Task 9: Config and docs

**Files:**
- Modify: `.gitignore`, `.env.example`, `README.md`

- [ ] **Step 1: `.gitignore`** — append:

```
demos/
```

- [ ] **Step 2: `.env.example`** — append:

```
# Signs the browser login cookie for the publish toggle on /index.
# Generate: ruby -rsecurerandom -e 'puts SecureRandom.hex(32)'
SESSION_SECRET=replace-with-64-hex-chars
# Base of the demo links shown on /index.
DEMOS_URL=https://demos.grillermo.com
# Port of the demos process (demos.grillermo.com tunnel route points here).
DEMO_PORT=33334
```

- [ ] **Step 3: `README.md`**
- Replace the "Run" section so it says `./serve` starts the tmux session `file_server` with the `files` (33333) and `demos` (33334, 127.0.0.1 only) panes, re-running restarts them, and `tmux attach -t file_server` shows them.
- Add a "## demos.grillermo.com" section covering:
  - files are public there only when copied into `demos/`
  - "Log in" on `/index` (Slack OTP) → "Make public" / "Public — unpublish"
  - curl: `curl -X POST https://files.chiq.me/publish -H "Authorization: Bearer $AUTH_TOKEN" -d name=<stored-name>` (and `/unpublish`)
  - the copy doesn't follow later overwrites (republish to refresh)
  - the demos process serves only `GET`/`HEAD /<name>` and 404s everything else
  - the Cloudflare route must point at `http://localhost:33334`
- In "Notes", add `GET /login`, `POST /auth/session`, `POST /logout`, `POST /publish`, `POST /unpublish` to the endpoint list.

- [ ] **Step 4: Full suite once more**

Run: `for f in test/*_test.rb; do ruby -Itest "$f" | tail -1; done`
Expected: every line ends in `0 failures, 0 errors`.

- [ ] **Step 5: Commit**

```bash
git add .gitignore .env.example README.md
git commit -m "docs: demos publishing, serve, new env vars"
```

---

## Manual steps for the user (after merge)

1. Cloudflare Zero Trust → the tunnel → public hostname `demos.grillermo.com` → service `http://localhost:33334`.
2. Add `SESSION_SECRET` to `.env` on the server host.
3. Run `./serve` (this replaces any foreground server on 33333).
4. Open `https://files.chiq.me/index` → Log in → Make public → open the demos link.
