# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
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
