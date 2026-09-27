# frozen_string_literal: true

require "rack/utils"
require "securerandom"

# The single live login code. Held in memory: the app is one process and has
# one user, so a restart simply voids a pending code.
class Otp
  TTL = 600
  MIN_INTERVAL = 30
  MAX_ATTEMPTS = 5

  class NotConfigured < StandardError; end
  class TooSoon < StandardError; end

  def initialize(notifier:, clock: -> { Time.now })
    @notifier = notifier
    @clock = clock
    @mutex = Mutex.new
    @code = nil
    @issued_at = nil
  end

  # Replaces any live code with a new one and delivers it. A failed delivery
  # voids the code and the rate limit, so an immediate retry is allowed.
  def issue(label)
    raise NotConfigured unless @notifier

    code = @mutex.synchronize { generate }
    @notifier.call("file_to_s3 OTP: #{code} (for #{label})")
  rescue NotConfigured, TooSoon
    raise
  rescue StandardError
    @mutex.synchronize { @code = @issued_at = nil }
    raise
  end

  # True at most once per code; MAX_ATTEMPTS wrong guesses discard it.
  def verify(candidate)
    @mutex.synchronize do
      return false unless @code && @clock.call < @expires_at

      if Rack::Utils.secure_compare(@code, candidate.to_s)
        @code = nil
        return true
      end

      @attempts += 1
      @code = nil if @attempts >= MAX_ATTEMPTS
      false
    end
  end

  private

  def generate
    now = @clock.call
    raise TooSoon if @issued_at && now - @issued_at < MIN_INTERVAL

    @issued_at = now
    @expires_at = now + TTL
    @attempts = 0
    @code = format("%06d", SecureRandom.random_number(1_000_000))
  end
end
