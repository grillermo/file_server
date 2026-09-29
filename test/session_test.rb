# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/session"

class SessionTest < Minitest::Test
  def setup
    @now = Time.at(1_000_000)
    @session = Session.new(secret: "s" * 64, clock: -> { @now })
  end

  def test_an_issued_value_is_valid
    assert @session.valid?(@session.issue)
  end

  def test_expires_after_the_ttl
    value = @session.issue
    @now += Session::TTL

    refute @session.valid?(value)
  end

  def test_a_tampered_expiry_is_rejected
    expires_at, mac = @session.issue.split(".")

    refute @session.valid?("#{expires_at.to_i + 1}.#{mac}")
  end

  def test_a_value_signed_with_another_secret_is_rejected
    other = Session.new(secret: "t" * 64, clock: -> { @now })

    refute @session.valid?(other.issue)
  end

  def test_garbage_is_rejected
    [nil, "", "abc", "123", "123.", ".abc", "x.y"].each do |value|
      refute @session.valid?(value), value.inspect
    end
  end

  def test_without_a_secret_nothing_is_valid_and_nothing_is_issued
    session = Session.new(secret: "")

    refute session.configured?
    refute session.valid?(@session.issue)
    assert_raises(RuntimeError) { session.issue }
  end
end
