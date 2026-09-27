# frozen_string_literal: true

ENV["AUTH_TOKEN"] = "test-token"

require "minitest/autorun"
require "fileutils"
require "json"
require "rack"
require "rack/mock_request"
require "tmpdir"
require_relative "../app"

class AppTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("file_server-test-")
    ENV["FILES_DIR"] = @dir
    @app = FileServerApp.new
  end

  def teardown
    ENV.delete("FILES_DIR")
    FileUtils.remove_entry(@dir)
  end

  # --- helpers ---------------------------------------------------------

  def write_temp(name, content)
    path = File.join(@dir, "..", "src-#{name}")
    File.write(path, content)
    path
  end

  def upload(path, filename, query: "")
    file = Rack::Multipart::UploadedFile.new(
      path, "application/octet-stream", true, filename: filename
    )
    env = Rack::MockRequest.env_for(
      "http://files.example/upload#{query}",
      method: "POST",
      params: { "file" => file },
      "HTTP_AUTHORIZATION" => "Bearer test-token"
    )
    @app.call(env)
  end

  def get(path)
    @app.call(Rack::MockRequest.env_for("http://files.example#{path}", method: "GET"))
  end

  def head(path)
    @app.call(Rack::MockRequest.env_for("http://files.example#{path}", method: "HEAD"))
  end

  def stored(name, content)
    File.write(File.join(@dir, name), content)
  end

  # --- files_dir override ----------------------------------------------

  def test_uploads_land_in_the_files_dir_override
    src = write_temp("a.txt", "hello")
    status, _, body = upload(src, "a.txt")

    assert_equal 200, status
    name = body.join.split("/files/").last
    assert_path_exists File.join(@dir, name)
  end

  # --- HEAD -------------------------------------------------------------

  def test_head_on_an_existing_file_matches_get
    stored("thing.plist", "<plist/>")

    get_status, get_headers, = get("/files/thing.plist")
    head_status, head_headers, head_body = head("/files/thing.plist")

    assert_equal 200, get_status
    assert_equal get_status, head_status
    assert_equal get_headers["content-type"], head_headers["content-type"]
    assert_equal "", head_body.to_a.join
  end

  def test_head_reports_the_length_without_a_body
    stored("thing.ipa", "0123456789")

    _, headers, body = head("/files/thing.ipa")

    assert_equal "10", headers["content-length"]
    assert_equal "", body.to_a.join
  end

  def test_get_streams_the_file_from_disk
    stored("big.bin", "x" * 200_000)

    _, headers, body = get("/files/big.bin")

    assert_equal File.join(@dir, "big.bin"), body.to_path
    chunks = body.to_enum(:each).to_a
    assert_operator chunks.size, :>, 1
    assert_equal "x" * 200_000, chunks.join
    assert_equal "200000", headers["content-length"]
  end

  def test_head_on_a_missing_file_is_404
    status, = head("/files/nope.txt")

    assert_equal 404, status
  end

  # --- pinned uploads ---------------------------------------------------

  def test_pinned_upload_uses_the_exact_name
    src = write_temp("m.plist", "<plist/>")

    status, _, body = upload(src, "ignored.plist", query: "?name=awh-manifest.plist")

    assert_equal 200, status
    assert_equal "http://files.example/files/awh-manifest.plist", body.join
    assert_path_exists File.join(@dir, "awh-manifest.plist")
  end

  def test_pinned_upload_overwrites_in_place
    first = write_temp("v1.plist", "one")
    second = write_temp("v2.plist", "two")

    _, _, first_body = upload(first, "x", query: "?name=awh-manifest.plist")
    _, _, second_body = upload(second, "x", query: "?name=awh-manifest.plist")

    assert_equal first_body.join, second_body.join
    assert_equal "two", File.read(File.join(@dir, "awh-manifest.plist"))
    assert_equal 1, Dir.children(@dir).size
  end

  def test_pinned_upload_sets_no_cache
    src = write_temp("m.plist", "<plist/>")

    _, headers, = upload(src, "x", query: "?name=awh-manifest.plist")

    assert_equal "no-cache", headers["cache-control"]
  end

  def test_pinned_name_cannot_escape_the_files_dir
    src = write_temp("m.plist", "pwned")

    status, _, body = upload(src, "x", query: "?name=../../etc/awh.plist")

    assert_equal 200, status
    assert_equal "http://files.example/files/awh.plist", body.join
    assert_path_exists File.join(@dir, "awh.plist")
  end

  def test_unpinned_upload_still_gets_a_uuid_prefix
    src = write_temp("a.txt", "hello")

    _, headers, body = upload(src, "a.txt")

    name = body.join.split("/files/").last
    assert_match(/\A[0-9a-f-]{36}-a\.txt\z/, name)
    assert_nil headers["cache-control"]
  end

  def test_a_blank_name_falls_back_to_the_uuid_prefix
    src = write_temp("a.txt", "hello")

    _, _, body = upload(src, "a.txt", query: "?name=")

    name = body.join.split("/files/").last
    assert_match(/\A[0-9a-f-]{36}-a\.txt\z/, name)
  end

  # --- health ---------------------------------------------------------

  def test_health_identifies_the_service
    status, headers, body = get("/health")

    assert_equal 200, status
    assert_equal "application/json", headers["content-type"]
    assert_equal({ "service" => "chiq-file-server" }, JSON.parse(body.join))
  end

  # --- public url -------------------------------------------------------

  def test_public_url_overrides_the_request_host
    ENV["PUBLIC_URL"] = "https://files.chiq.me/"
    src = write_temp("m.plist", "<plist/>")

    _, _, body = upload(src, "x", query: "?name=awh-manifest.plist")

    assert_equal "https://files.chiq.me/files/awh-manifest.plist", body.join
  ensure
    ENV.delete("PUBLIC_URL")
  end

  # --- index ------------------------------------------------------------

  def test_index_lists_every_file
    stored("a.txt", "one")
    stored("b.txt", "two")

    status, headers, body = get("/index")
    html = body.join

    assert_equal 200, status
    assert_includes headers["content-type"], "text/html"
    assert_includes html, "a.txt"
    assert_includes html, "b.txt"
  end

  def test_index_links_to_each_file
    stored("a b.txt", "one")

    _, _, body = get("/index")

    assert_includes body.join, "/files/a%20b.txt"
  end

  def test_index_escapes_html_in_filenames
    stored("a_script_.txt", "one")
    File.rename(File.join(@dir, "a_script_.txt"), File.join(@dir, "a<b>.txt"))

    _, _, body = get("/index")
    html = body.join

    refute_includes html, "a<b>.txt"
    assert_includes html, "a&lt;b&gt;.txt"
  end

  def test_index_is_mobile_friendly
    stored("a.txt", "one")

    _, _, body = get("/index")

    assert_includes body.join, %(name="viewport")
  end

  def test_index_orders_newest_first
    stored("old.txt", "one")
    stored("new.txt", "two")
    File.utime(Time.now - 3600, Time.now - 3600, File.join(@dir, "old.txt"))

    _, _, body = get("/index")
    html = body.join

    assert_operator html.index("new.txt"), :<, html.index("old.txt")
  end

  def test_index_on_an_empty_dir_still_renders
    status, _, body = get("/index")

    assert_equal 200, status
    assert_includes body.join, "No files"
  end
end
