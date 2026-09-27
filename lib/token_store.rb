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
