# frozen_string_literal: true

require "spec_helper"
require_relative "../../gui/auth"

RSpec.describe RubyCoincheckClient::GUI::Auth do
  let(:clock) { [100.0] }
  let(:password) { "this-is-a-test-passphrase" }
  let(:auth) { described_class.new(password, clock: -> { clock.first }) }

  it "requires a password and never accepts a weak default" do
    [nil, "", "short", " " * 20].each do |value|
      expect { described_class.new(value) }.to raise_error(ArgumentError)
    end
  end

  it "requires the correct password and issues an unpredictable expiring session" do
    expect(auth.valid?(nil)).to eq(false)
    expect(auth.login("wrong").first).to eq(:invalid)
    status, id = auth.login(password)
    expect(status).to eq(:ok)
    expect(id).to match(/\A[0-9a-f]{64}\z/)
    expect(auth.valid?(id)).to eq(true)
    clock[0] += described_class::SESSION_SECONDS
    expect(auth.valid?(id)).to eq(false)
  end

  it "rotates existing sessions and invalidates them on logout" do
    _, first = auth.login(password)
    _, second = auth.login(password, previous_id: first)
    expect(second).not_to eq(first)
    expect(auth.valid?(first)).to eq(false)
    auth.logout(second)
    expect(auth.valid?(second)).to eq(false)
  end

  it "limits repeated failures even if requests claim different source addresses" do
    described_class::MAX_FAILURES.times { expect(auth.login("wrong").first).to eq(:invalid) }
    expect(auth.login(password).first).to eq(:limited)
    clock[0] += described_class::RETRY_SECONDS
    expect(auth.login(password).first).to eq(:ok)
  end
end
