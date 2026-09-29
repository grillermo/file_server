require "date"
require "dotenv/load"
require "erb"
require "fileutils"
require "json"
require "rack"
require "securerandom"
require "uri"
require_relative "lib/file_body"
require_relative "lib/otp"
require_relative "lib/publisher"
require_relative "lib/session"
require_relative "lib/slack_notifier"
require_relative "lib/token_store"

class FileServerApp
  # Served from files/ like any upload, but owned by the repo.
  RESERVED_NAMES = ["mcp.html"].freeze
  SERVICE_ID = "chiq-file-server"

  def initialize(otp: Otp.new(notifier: SlackNotifier.from_env),
                 tokens: TokenStore.new(ENV.fetch("TOKENS_FILE") { File.join(__dir__, "tokens.json") }),
                 session: Session.from_env)
    @otp = otp
    @tokens = tokens
    @session = session
  end

  def call(env)
    req = Rack::Request.new(env)

    case [req.request_method, req.path_info]
    in ["POST", "/upload"]
      return unauthorized unless authenticated?(req)

      handle_upload(req)
    in ["POST", "/receive"]
      return unauthorized unless authenticated?(req)

      handle_receive(req)
    in ["POST", "/auth/otp"]
      request_otp(req)
    in ["POST", "/auth/verify"]
      verify_otp(req)
    in ["GET", "/login"]
      serve_login
    in ["POST", "/auth/session"]
      start_session(req)
    in ["POST", "/logout"]
      end_session
    # Cookie-authenticated POSTs rely on SameSite=Strict, which holds only while
    # files.chiq.me and demos.grillermo.com are different registrable domains (a
    # demo page can't send the cookie). If they ever share one, add an
    # Origin/Sec-Fetch-Site check here.
    in ["POST", ("/publish" | "/unpublish") => action]
      return unauthorized unless logged_in?(req) || authenticated?(req)

      toggle_publish(req, action)
    in ["GET", "/health"]
      health(req)
    in ["GET", "/"]
      serve_index(req)
    in ["GET", "/index"]
      serve_listing(req)
    in ["GET" | "HEAD", path] if path.start_with?("/files/")
      serve_file(path.delete_prefix("/files/"), head: req.request_method == "HEAD")
    else
      not_found
    end
  rescue StandardError => e
    error_page(e)
  end

  private

  # AUTH_TOKEN is the Shortcuts' shared secret; fts_ tokens come from an MCP
  # login and never expire until revoked with bin/tokens.
  def authenticated?(req)
    token = bearer_token(req)
    return false unless token

    Rack::Utils.secure_compare(token, ENV.fetch("AUTH_TOKEN")) || @tokens.valid?(token)
  end

  def bearer_token(req)
    req.get_header("HTTP_AUTHORIZATION").to_s[/\ABearer\s+(.+)\z/, 1]
  end

  # Before sending its token to a LAN address, the MCP asks for proof that the
  # server there holds that token: ?nonce=<hex>&token_id=<digest prefix>. The
  # proof is bound to the Host the client dialled, so a device on the LAN
  # relaying the challenge through the tunnel gets a proof for files.chiq.me,
  # which the client rejects. The raw Host header is used on purpose:
  # req.host_with_port trusts X-Forwarded-Host, which a relay could forge.
  def health(req)
    body = { service: SERVICE_ID }
    nonce = req.params["nonce"].to_s
    host = req.get_header("HTTP_HOST").to_s
    if nonce.match?(/\A\h{32,64}\z/) && !host.empty? && !req.get_header("HTTP_CF_CONNECTING_IP")
      proof = @tokens.prove(req.params["token_id"], "#{nonce}\n#{host}")
      body[:proof] = proof if proof
    end
    [200, { "content-type" => "application/json", "cache-control" => "no-store" }, [body.to_json]]
  end

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

  # Copies into (or deletes from) demos/, which the separate demos process
  # serves. Dotfiles are refused because the demos app never serves them.
  def toggle_publish(req, action)
    raw = req.params["name"].to_s
    return unprocessable("invalid name") if raw.include?("\0")

    name = File.basename(raw)
    return unprocessable("#{name} can't be published") unless publishable?(name)

    action == "/publish" ? publisher.publish(name) : publisher.unpublish(name)
    redirect("/index")
  rescue Publisher::NotFound
    not_found
  rescue SystemCallError => e
    warn "[publish] #{e.class}: #{e.message}"
    text_response(500, "Could not update demos")
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

  def handle_upload(req)
    uploaded = extract_uploaded_file(req)
    return uploaded unless uploaded.is_a?(Hash)

    pinned = pinned_name(req)
    return unprocessable("#{pinned} is reserved") if pinned && RESERVED_NAMES.include?(pinned.downcase)

    filename = pinned || build_local_filename(uploaded[:filename])
    FileUtils.mkdir_p(files_dir)

    uploaded[:tempfile].rewind
    File.open(File.join(files_dir, filename), "wb") do |file|
      IO.copy_stream(uploaded[:tempfile], file)
    end

    # A pinned file is overwritten in place, so its URL is stable and every
    # cache in front of it — Cloudflare especially — must revalidate rather
    # than serve the previous release.
    headers = pinned ? { "cache-control" => "no-cache" } : {}
    text_response(200, file_url(req, filename), headers)
  end

  def handle_receive(req)
    uploaded = extract_uploaded_file(req)
    return uploaded unless uploaded.is_a?(Hash)

    path = File.join(files_dir, build_local_filename(uploaded[:filename]))
    FileUtils.mkdir_p(files_dir)

    uploaded[:tempfile].rewind
    File.open(path, "wb") do |file|
      IO.copy_stream(uploaded[:tempfile], file)
    end

    text_response(200, path)
  end

  def extract_uploaded_file(req)
    uploaded = req.params["file"]

    return unprocessable("Missing multipart file field 'file'.") unless uploaded.is_a?(Hash)

    tempfile = uploaded[:tempfile]
    filename = sanitize_filename(uploaded[:filename])

    return unprocessable("The uploaded file payload was invalid.") unless tempfile && filename

    size = tempfile.size
    return unprocessable("The file is empty.") if size.zero?

    {
      tempfile: tempfile,
      filename: filename,
      content_type: uploaded[:type]
    }
  end

  def build_local_filename(filename)
    "#{SecureRandom.uuid}-#{filename}"
  end

  # ?name=awh-manifest.plist stores the upload under exactly that name,
  # overwriting any previous one, so the URL never changes. Runs through the
  # same sanitizer as an uploaded filename, so it cannot escape files_dir.
  def pinned_name(req)
    requested = req.params["name"]
    return nil if requested.to_s.strip.empty?

    sanitize_filename(requested)
  end

  def sanitize_filename(filename)
    return nil if filename.to_s.strip.empty?

    File.basename(filename).gsub(/[^\w.\-]/, "_")
  end

  # Overridable so tests can point at a scratch directory instead of the
  # repo's real files/.
  def files_dir
    ENV.fetch("FILES_DIR") { File.join(__dir__, "files") }
  end

  def text_response(status, body, extra_headers = {})
    headers = { "content-type" => "text/plain; charset=utf-8" }.merge(extra_headers)
    [status, headers, [body]]
  end

  def unprocessable(message)
    text_response(422, message)
  end

  def unauthorized
    [
      401,
      {
        "content-type" => "text/plain; charset=utf-8",
        "www-authenticate" => %(Bearer realm="file_server")
      },
      ["Unauthorized"]
    ]
  end

  def not_found
    text_response(404, "Not found")
  end

  def error_page(error)
    warn "[file_server] #{error.class}: #{error.message}"
    text_response(500, error.message)
  end

  def latest_filename
    Dir.children(files_dir)
      .map { |name| File.join(files_dir, name) }
      .select { |path| File.file?(path) && !RESERVED_NAMES.include?(File.basename(path).downcase) }
      .max_by { |path| File.mtime(path) }
      &.then { |path| File.basename(path) }
  end

  def serve_index(req)
    filename = File.directory?(files_dir) ? latest_filename : nil
    return [200, { "content-type" => "text/html; charset=utf-8" }, ["<html><body><p>No file uploaded yet.</p></body></html>"]] unless filename

    url = file_url(req, filename)
    html = <<~HTML
      <!DOCTYPE html>
      <html>
      <head><title>Downloading...</title></head>
      <body>
      <script>window.location.href = #{url.to_json};</script>
      <p>Downloading... <a href=#{url.to_json}>click here if it doesn't start</a></p>
      </body>
      </html>
    HTML
    [200, { "content-type" => "text/html; charset=utf-8" }, [html]]
  end

  # Every stored file, newest first, as [name, size, mtime].
  def listing_entries
    return [] unless File.directory?(files_dir)

    Dir.children(files_dir)
      .map { |name| [name, File.join(files_dir, name)] }
      .select { |_, path| File.file?(path) }
      .sort_by { |_, path| -File.mtime(path).to_f }
      .map { |name, path| [name, File.size(path), File.mtime(path)] }
  end

  def serve_listing(req)
    logged_in = logged_in?(req)
    entries = listing_entries
    body = entries.empty? ? %(<p class="empty">No files uploaded yet.</p>) : timeline_groups(req, entries, logged_in)

    html = <<~HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Files</title>
      <style>#{listing_css}</style>
      </head>
      <body>
      <header>#{auth_control(logged_in)}<h1>Files</h1><p class="count">#{entries.size} #{entries.size == 1 ? "file" : "files"}</p></header>
      #{body}
      </body>
      </html>
    HTML

    [200, { "content-type" => "text/html; charset=utf-8", "cache-control" => "private, no-store", "vary" => "Cookie" }, [html]]
  end

  TIMELINE_BASE = [173, 27, 26].freeze
  TIMELINE_END = [205, 196, 196].freeze
  TIMELINE_MAX_MONTHS = 6
  # Buckets 0..6 are day/week ranges; 7.. are whole months ago (1 .. 6+).
  TIMELINE_DAY_LABELS = ["Today", "1 day ago", "2 days ago", "A few days ago",
                         "1 week ago", "2 weeks ago", "3 weeks ago"].freeze
  TIMELINE_LAST_BUCKET = TIMELINE_DAY_LABELS.size - 1 + TIMELINE_MAX_MONTHS

  def age_bucket(mtime, now = Time.now)
    days = (now.to_date - mtime.to_date).to_i
    case days
    when ..0 then 0
    when 1, 2 then days
    when 3..6 then 3
    when 7..13 then 4
    when 14..20 then 5
    when 21..27 then 6
    else
      months = (now.year - mtime.year) * 12 + (now.month - mtime.month)
      TIMELINE_DAY_LABELS.size - 1 + months.clamp(1, TIMELINE_MAX_MONTHS)
    end
  end

  def bucket_label(bucket)
    return TIMELINE_DAY_LABELS[bucket] if bucket < TIMELINE_DAY_LABELS.size

    months = bucket - TIMELINE_DAY_LABELS.size + 1
    return "#{TIMELINE_MAX_MONTHS}+ months ago" if months == TIMELINE_MAX_MONTHS

    "#{months} month#{"s" if months > 1} ago"
  end

  def bucket_color(bucket)
    t = bucket.to_f / TIMELINE_LAST_BUCKET
    r, g, b = TIMELINE_BASE.zip(TIMELINE_END).map { |from, to| (from + (to - from) * t).round }
    "rgb(#{r}, #{g}, #{b})"
  end

  # Consecutive entries (already newest first) sharing a month bucket get one
  # sticky marker pill, and each row gets a dot on the timeline rail.
  def timeline_groups(req, entries, logged_in)
    entries.chunk_while { |a, b| age_bucket(a[2]) == age_bucket(b[2]) }.map do |group|
      range = age_bucket(group.first[2])
      color = bucket_color(range)
      rows = group.map { |name, size, mtime| listing_row(req, name, size, mtime, logged_in) }.join("\n")

      <<~GROUP
        <section class="group" style="--marker: #{color}">
        <div class="marker"><span class="pill">#{bucket_label(range)}</span></div>
        <ul class="files">
        #{rows}
        </ul>
        </section>
      GROUP
    end.join("\n")
  end

  # Names carry a UUID prefix; the prefix is dimmed rather than dropped so the
  # displayed name always matches the stored one — nothing is truncated.
  def listing_row(req, name, size, mtime, logged_in)
    prefix, rest = name.match(/\A([0-9a-f-]{36}-)(.+)\z/m)&.captures || [nil, name]
    label = [
      prefix && %(<span class="uuid">#{escape_html(prefix)}</span>),
      %(<span class="stem">#{escape_html(rest)}</span>)
    ].compact.join

    <<~ROW
      <li><span class="rail"></span><a href="#{escape_html(file_url(req, name))}">
      <span class="name">#{label}</span>
      <span class="meta">#{human_size(size)} &middot; #{mtime.strftime("%Y-%m-%d %H:%M")}</span>
      </a>#{publish_controls(name) if logged_in && publishable?(name)}</li>
    ROW
  end

  def auth_control(logged_in)
    return %(<a class="auth" href="/login">Log in</a>) unless logged_in

    %(<form class="auth" method="post" action="/logout"><button type="submit">Log out</button></form>)
  end

  # A form beside the row's link (a form can't sit inside an <a>). Posts to
  # /publish or /unpublish, which redirect back here.
  def publish_controls(name)
    if publisher.published?(name)
      url = escape_html(demo_url(name))
      action, label, link = "/unpublish", "Public — unpublish", %(<a class="demo" href="#{url}">#{url}</a>)
      aria = "Unpublish #{escape_html(name)}"
    else
      action, label, link = "/publish", "Make public", ""
      aria = "Make #{escape_html(name)} public"
    end

    <<~FORM
      <form class="publish" method="post" action="#{action}">
      <input type="hidden" name="name" value="#{escape_html(name)}">
      <button type="submit" aria-label="#{aria}">#{label}</button>#{link}
      </form>
    FORM
  end

  def demo_url(name)
    base = ENV.fetch("DEMOS_URL", "https://demos.grillermo.com").chomp("/")
    "#{base}/#{ERB::Util.url_encode(name)}"
  end

  UNITS = ["B", "KB", "MB", "GB"].freeze

  def human_size(bytes)
    value = bytes.to_f
    unit = 0
    while value >= 1024 && unit < UNITS.size - 1
      value /= 1024
      unit += 1
    end

    format(unit.zero? || value >= 10 ? "%.0f %s" : "%.1f %s", value, UNITS[unit])
  end

  def escape_html(text)
    Rack::Utils.escape_html(text.to_s)
  end

  def listing_css
    <<~CSS
      :root { color-scheme: light dark; --bg: #f6f6f7; --card: #fff; --fg: #16161a; --dim: #74747e; --line: #e3e3e7; --accent: #2f6fed; }
      @media (prefers-color-scheme: dark) {
        :root { --bg: #111114; --card: #1b1b20; --fg: #f2f2f4; --dim: #9a9aa4; --line: #2a2a32; --accent: #7ea6ff; }
      }
      * { box-sizing: border-box; }
      body { margin: 0; padding: 1rem 1rem 3rem; background: var(--bg); color: var(--fg);
             font: 16px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
      header { max-width: 46rem; margin: 0 auto .75rem; }
      h1 { font-size: 1.25rem; margin: .25rem 0; }
      .count { margin: 0; color: var(--dim); font-size: .85rem; }
      .empty { max-width: 46rem; margin: 2rem auto; color: var(--dim); }
      .group { max-width: 46rem; margin: 0 auto; }
      .marker { position: sticky; top: 0; z-index: 1; display: flex; align-items: center; gap: .5rem;
                padding: .75rem 0 .4rem; background: color-mix(in srgb, var(--bg) 95%, transparent);
                backdrop-filter: blur(6px); }
      .marker::after { content: ""; flex: 1; height: 1px; background: var(--line); }
      .pill { padding: .1rem .65rem; border-radius: 999px; background: var(--marker); color: #fff;
              font-size: .7rem; font-weight: 600; }
      ul.files { list-style: none; margin: 0; padding: 0; }
      ul.files li { display: flex; gap: .75rem; }
      .rail { position: relative; flex: 0 0 1.25rem; }
      .rail::before { content: ""; position: absolute; top: 0; bottom: 0; left: 50%; width: 2px;
                      transform: translateX(-50%); background: var(--line); }
      .rail::after { content: ""; position: absolute; top: 1.4rem; left: 50%; width: .65rem; height: .65rem;
                     transform: translateX(-50%); border-radius: 50%; background: var(--marker);
                     border: 2px solid var(--bg); box-sizing: content-box; }
      ul.files a { flex: 1; min-width: 0; display: block; margin: .25rem 0; padding: .8rem 1rem; color: inherit;
                   text-decoration: none; background: var(--card); border: 1px solid var(--line); border-radius: 12px; }
      ul.files a:active { background: var(--line); }
      /* Names wrap in full — never clipped, never ellipsised. */
      .name { display: block; overflow-wrap: anywhere; word-break: break-word; hyphens: none; }
      .uuid { color: var(--dim); font-size: .8em; }
      .stem { color: var(--accent); }
      .meta { display: block; margin-top: .2rem; color: var(--dim); font-size: .8rem; }
      button { font: inherit; font-size: .8rem; padding: .3rem .7rem; border: 1px solid var(--line);
               border-radius: 8px; background: var(--card); color: inherit; }
      .auth { float: right; margin: .3rem 0 0; font-size: .85rem; color: var(--accent); }
      .login { max-width: 46rem; margin: 0 auto; display: grid; gap: .75rem; justify-items: start; }
      .login form { display: flex; gap: .5rem; }
      .login input { font: inherit; padding: .4rem .7rem; border: 1px solid var(--line); border-radius: 8px;
                     background: var(--card); color: inherit; }
      form.publish { display: flex; flex-wrap: wrap; gap: .5rem; align-items: center; margin: 0; padding: 0 1rem .8rem; }
      ul.files a.demo { display: inline; padding: 0; color: var(--accent); font-size: .8rem; overflow-wrap: anywhere; }
      @media (min-width: 40rem) { body { padding: 2rem 1.5rem 4rem; } }
    CSS
  end

  # iOS's install daemon issues HEAD (and Range) for the OTA manifest and the
  # .ipa before it downloads either, so HEAD must answer with the same status
  # and headers as GET — just without the body.
  def serve_file(filename, head: false)
    safe_name = File.basename(filename)
    path = File.join(files_dir, safe_name)

    return not_found unless File.file?(path)

    headers = FileBody.headers(path)
    return [200, headers, []] if head

    [200, headers, FileBody.new(path)]
  end

  # PUBLIC_URL pins links to the tunnel's hostname, so an upload sent straight
  # to the LAN address still returns a URL that works from anywhere.
  def file_url(req, filename)
    base = ENV.fetch("PUBLIC_URL") { req.base_url }.chomp("/")
    "#{base}/files/#{URI::DEFAULT_PARSER.escape(filename)}"
  end
end
