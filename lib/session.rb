# frozen_string_literal: true

require "openssl"
require "rack/utils"

# Browser login for the publish toggle. The cookie value is
# "<issued_at>.<hmac>" signed with SESSION_SECRET, so nothing is stored
# server-side. A session never expires; changing the secret logs every browser out.
class Session
  COOKIE = "fs_session"
  # The longest browsers keep a cookie (Chrome caps it at 400 days).
  COOKIE_MAX_AGE = 400 * 24 * 60 * 60

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

    issued_at = @clock.call.to_i.to_s
    "#{issued_at}.#{sign(issued_at)}"
  end

  def valid?(value)
    return false unless configured?

    value = value.to_s
    return false unless value.valid_encoding?

    issued_at, mac = value.split(".", 2)
    return false unless issued_at&.match?(/\A\d+\z/) && !mac.to_s.empty?

    Rack::Utils.secure_compare(sign(issued_at), mac)
  end

  private

  def sign(data)
    OpenSSL::HMAC.hexdigest("SHA256", @secret, data)
  end
end
