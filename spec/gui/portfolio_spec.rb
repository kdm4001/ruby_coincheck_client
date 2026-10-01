# frozen_string_literal: true

require "spec_helper"
require_relative "../../gui/portfolio"

RSpec.describe RubyCoincheckClient::GUI::Portfolio do
  let(:rates) { instance_double(RubyCoincheckClient::Client) }
  let(:clock) { [100.0] }
  let(:portfolio) { described_class.new(rate_client: rates, clock: -> { clock.first }) }

  it "includes cash, reserved, lending and accumulation balances and subtracts debt" do
    expect(rates).to receive(:rate).with(pair: "btc_jpy").and_return("rate" => "1000")
    result = portfolio.call(
      "success" => true, "jpy" => "1000", "jpy_reserved" => "500", "jpy_tsumitate" => "200",
      "btc" => "0.1", "btc_reserved" => "0.2", "btc_lending" => "0.3",
      "btc_lend_in_use" => "0.4", "btc_lent" => "0.5", "btc_tsumitate" => "0.6", "btc_debt" => "0.1"
    )
    expect(result[:total_jpy]).to eq("3700.0")
    btc = result[:assets].find { |asset| asset[:currency] == "btc" }
    expect(btc).to include(quantity: "2.0", other: "1.8", debt: "0.1", value_jpy: "2000.0")
    expect(result[:assets].map { |asset| asset[:currency] }).to eq(%w[jpy btc eth xrp sol])
  end

  it "values every held currency, even outside the market selector" do
    expect(rates).to receive(:rate).with(pair: "dai_jpy").and_return("rate" => "150.5")
    result = portfolio.call("dai_reserved" => "2", "jpy" => "100")
    expect(result[:total_jpy]).to eq("401.0")
    expect(result[:assets].last).to include(currency: "dai", quantity: "2.0", value_jpy: "301.0")
  end

  it "calculates decimal quantities without floating-point rounding errors" do
    expect(rates).to receive(:rate).with(pair: "btc_jpy").and_return("rate" => "0.1")
    result = portfolio.call("jpy" => "10000.1", "btc" => "0.1", "btc_reserved" => "0.2")
    expect(result[:total_jpy]).to eq("10000.13")
  end

  it "marks a missing quote as unvalued instead of silently reducing total assets" do
    expect(rates).to receive(:rate).with(pair: "sol_jpy").and_raise(Net::ReadTimeout)
    result = portfolio.call("jpy" => "1000", "sol" => "2")
    expect(result[:total_jpy]).to be_nil
    expect(result[:valued_jpy]).to eq("1000.0")
    expect(result[:missing_rates]).to eq(["sol"])
    expect(result[:assets].find { |asset| asset[:currency] == "sol" }[:value_jpy]).to be_nil
  end

  it "skips quote requests for empty balances but preserves a real zero valuation" do
    expect(rates).not_to receive(:rate)
    result = portfolio.call("jpy" => "0", "btc" => "0", "dai" => "0")
    expect(result[:total_jpy]).to eq("0.0")
    expect(result[:missing_rates]).to be_empty
    expect(result[:assets].map { |asset| asset[:currency] }).not_to include("dai")
  end

  it "does not reuse expired quotes when the replacement request fails" do
    expect(rates).to receive(:rate).with(pair: "xrp_jpy").once.and_return("rate" => "100")
    2.times { expect(portfolio.call("xrp" => "5")[:total_jpy]).to eq("500.0") }
    clock[0] += described_class::RATE_TTL
    expect(rates).to receive(:rate).with(pair: "xrp_jpy").once.and_return("rate" => "0")
    expect(portfolio.call("xrp" => "5")[:total_jpy]).to be_nil
  end

  it "rejects invalid balances instead of displaying a false total" do
    expect { portfolio.call("btc" => "NaN") }.to raise_error(RubyCoincheckClient::ResponseError)
    expect { portfolio.call("jpy" => nil) }.to raise_error(RubyCoincheckClient::ResponseError)
  end
end
