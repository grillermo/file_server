# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

# Posts a message to a Slack incoming webhook — the same call rulinky's
# SlackOtpNotifier makes, pointed at the #otp channel.
class SlackNotifier
  def self.from_env
    url = ENV["SLACK_OTP_WEBHOOK_URL"].to_s.strip
    url.empty? ? nil : new(url)
  end

  def initialize(url)
    @uri = URI(url)
  end

  def call(text)
    response = Net::HTTP.post(@uri, { text: text }.to_json, "Content-Type" => "application/json")
    raise "Slack webhook returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)
  end
end
