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
