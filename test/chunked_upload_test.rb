# frozen_string_literal: true

ENV["AUTH_TOKEN"] = "test-token"

require "minitest/autorun"
require "digest"
require "fileutils"
require "rack"
require "rack/mock_request"
require "securerandom"
require "tmpdir"
require_relative "../app"

class ChunkedUploadTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("file_server-chunks-")
    @files = File.join(@root, "files")
    @parts = File.join(@root, "parts")
    Dir.mkdir(@files)
    ENV["FILES_DIR"] = @files
    ENV["PARTS_DIR"] = @parts
    @app = FileServerApp.new(session: Session.new(secret: "s" * 64))
    @id = SecureRandom.hex(16)
  end

  def teardown
    ENV.delete("FILES_DIR")
    ENV.delete("PARTS_DIR")
    FileUtils.remove_entry(@root)
  end

  def post(path, query, file: nil, token: "test-token")
    params = {}
    if file
      src = File.join(@root, "src-#{SecureRandom.hex(4)}")
      File.binwrite(src, file)
      params["file"] = Rack::Multipart::UploadedFile.new(src, "application/octet-stream", true, filename: "part")
    end
    env = Rack::MockRequest.env_for("http://files.example#{path}?#{URI.encode_www_form(query)}",
                                    method: "POST", params: params,
                                    "HTTP_AUTHORIZATION" => "Bearer #{token}")
    status, headers, body = @app.call(env)
    [status, headers, body.join]
  end

  def send_parts(slices, id: @id)
    slices.each_with_index do |slice, i|
      status, _, body = post("/upload/part", { upload_id: id, part: i }, file: slice)
      assert_equal 200, status, body
    end
  end

  def assemble(data, parts:, name: "App-1.0.0.ipa", sha256: Digest::SHA256.hexdigest(data), size: data.bytesize)
    post("/upload/assemble", { upload_id: @id, name: name, parts: parts, size: size, sha256: sha256 })
  end

  def test_parts_join_into_the_pinned_name_and_the_parts_are_removed
    data = SecureRandom.random_bytes(300_000)
    send_parts([data[0, 100_000], data[100_000, 100_000], data[200_000..]])

    status, headers, body = assemble(data, parts: 3)

    assert_equal 200, status, body
    assert_equal "http://files.example/files/App-1.0.0.ipa", body
    assert_equal "no-cache", headers["cache-control"]
    assert_equal data, File.binread(File.join(@files, "App-1.0.0.ipa"))
    assert_equal 0o644, File.stat(File.join(@files, "App-1.0.0.ipa")).mode & 0o777
    assert_equal ["App-1.0.0.ipa"], Dir.children(@files)
    refute File.exist?(File.join(@parts, @id))
  end

  def test_a_retried_part_replaces_the_earlier_attempt
    send_parts(%w[aa XX])
    send_parts(%w[aa bb])

    status, = assemble("aabb", parts: 2)

    assert_equal 200, status
    assert_equal "aabb", File.read(File.join(@files, "App-1.0.0.ipa"))
  end

  def test_assembling_overwrites_the_previous_release
    File.write(File.join(@files, "App-1.0.0.ipa"), "old")
    send_parts(%w[new])

    assemble("new", parts: 1)

    assert_equal "new", File.read(File.join(@files, "App-1.0.0.ipa"))
  end

  def test_a_missing_part_is_refused_and_the_target_left_alone
    File.write(File.join(@files, "App-1.0.0.ipa"), "old")
    send_parts(%w[aa])

    status, _, body = assemble("aabb", parts: 2)

    assert_equal 422, status
    assert_match(/missing parts: 1/, body)
    assert_equal "old", File.read(File.join(@files, "App-1.0.0.ipa"))
  end

  def test_a_checksum_mismatch_is_refused_and_leaves_nothing_behind
    send_parts(%w[aa bb])

    status, _, body = assemble("aabb", parts: 2, sha256: "0" * 64)

    assert_equal 422, status
    assert_match(/sha256/, body)
    assert_empty Dir.children(@files)
  end

  def test_a_size_mismatch_is_refused
    send_parts(%w[aa bb])

    status, _, body = assemble("aabb", parts: 2, size: 5)

    assert_equal 422, status
    assert_match(/expected 5/, body)
  end

  def test_a_bad_upload_id_cannot_escape_the_parts_dir
    status, _, body = post("/upload/part", { upload_id: "../../etc", part: 0 }, file: "x")

    assert_equal 422, status
    assert_match(/upload_id/, body)
  end

  def test_a_name_with_a_path_is_sanitized
    send_parts(%w[aa])

    status, _, body = assemble("aa", parts: 1, name: "../escape.ipa")

    assert_equal 200, status
    assert_equal "http://files.example/files/escape.ipa", body
    assert File.exist?(File.join(@files, "escape.ipa"))
  end

  def test_both_endpoints_need_the_token
    assert_equal 401, post("/upload/part", { upload_id: @id, part: 0 }, file: "x", token: "wrong").first
    assert_equal 401, post("/upload/assemble", { upload_id: @id, name: "a", parts: 1 }, token: "wrong").first
  end

  def test_stale_uploads_are_swept_when_a_new_part_arrives
    stale = File.join(@parts, "a" * 32)
    FileUtils.mkdir_p(stale)
    old = Time.now - ChunkedUpload::STALE_AFTER - 60
    File.utime(old, old, stale)

    send_parts(%w[aa])

    refute File.exist?(stale)
  end
end
