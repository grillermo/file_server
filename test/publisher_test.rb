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
