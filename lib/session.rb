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
