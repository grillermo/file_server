# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "socket"
require_relative "../lib/otp"
require_relative "../lib/slack_notifier"

class OtpTest < Minitest::Test
  def setup
    @now = Time.at(1_000_000)
    @sent = []
    @otp = Otp.new(notifier: ->(text) { @sent << text }, clock: -> { @now })
  end

  def code
    @sent.last[/\d{6}/]
  end

  def test_issue_sends_a_six_digit_code_with_the_label
    @otp.issue("laptop")

    assert_match(/\Afile_server OTP: \d{6} \(for laptop\)\z/, @sent.last)
  end

  def test_correct_code_verifies_exactly_once
    @otp.issue("laptop")
    live = code

    assert @otp.verify(live)
    refute @otp.verify(live)
  end

  def test_wrong_code_fails
    @otp.issue("laptop")

    refute @otp.verify("wrong")
  end

  def test_verify_without_an_issued_code_fails
    refute @otp.verify("123456")
  end

  def test_expired_code_fails
    @otp.issue("laptop")
    live = code
    @now += Otp::TTL

    refute @otp.verify(live)
  end

  def test_four_wrong_attempts_still_allow_the_right_code
    @otp.issue("laptop")
    live = code
    4.times { refute @otp.verify("wrong") }

    assert @otp.verify(live)
  end

  def test_fifth_wrong_attempt_discards_the_code
    @otp.issue("laptop")
    live = code
    5.times { refute @otp.verify("wrong") }

    refute @otp.verify(live)
  end

  def test_second_issue_within_the_interval_is_too_soon
    @otp.issue("laptop")
    @now += Otp::MIN_INTERVAL - 1

    assert_raises(Otp::TooSoon) { @otp.issue("laptop") }
    assert_equal 1, @sent.size
  end

  def test_new_code_replaces_the_old_one
    @otp.issue("laptop")
    old = code
    @now += Otp::MIN_INTERVAL
    @otp.issue("laptop")

    refute @otp.verify(old) unless old == code
    assert @otp.verify(code)
  end

  def test_without_a_notifier_issue_is_not_configured
    otp = Otp.new(notifier: nil)

    assert_raises(Otp::NotConfigured) { otp.issue("laptop") }
  end

  def test_failed_delivery_does_not_rate_limit_the_retry
    failing = true
    otp = Otp.new(notifier: ->(text) { failing ? raise("slack down") : @sent << text }, clock: -> { @now })

    assert_raises(RuntimeError) { otp.issue("laptop") }
    failing = false
    otp.issue("laptop")

    assert otp.verify(code)
  end
end

class SlackNotifierTest < Minitest::Test
  def test_from_env_is_nil_when_the_webhook_is_blank
    with_env("SLACK_OTP_WEBHOOK_URL" => "  ") { assert_nil SlackNotifier.from_env }
    with_env("SLACK_OTP_WEBHOOK_URL" => nil) { assert_nil SlackNotifier.from_env }
  end

  def test_call_posts_json_text
    server = TCPServer.new("127.0.0.1", 0)
    received = Thread.new do
      client = server.accept
      headers = {}
      client.gets
      while (line = client.gets) != "\r\n"
        name, value = line.split(":", 2)
        headers[name.downcase] = value.strip
      end
      body = client.read(headers["content-length"].to_i)
      client.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
      client.close
      body
    end

    SlackNotifier.new("http://127.0.0.1:#{server.addr[1]}/hook").call("hi")

    assert_equal({ "text" => "hi" }, JSON.parse(received.value))
  ensure
    server&.close
  end

  private

  def with_env(vars)
    saved = vars.keys.to_h { |key| [key, ENV[key]] }
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| ENV[key] = value }
  end
end
