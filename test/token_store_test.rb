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
