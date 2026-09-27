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
    assert_includes html, "claude mcp add --scope user file_server -- ruby ~/c/agents-configs/mcp/file_server/server.rb"
    assert_includes html, "bin/tokens revoke"
  end

  def test_page_is_served_as_html
    ENV["FILES_DIR"] = File.dirname(PAGE)
    status, headers, = FileServerApp.new.call(Rack::MockRequest.env_for("http://files.example/files/mcp.html"))

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
