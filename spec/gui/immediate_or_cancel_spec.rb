# frozen_string_literal: true

require "spec_helper"
require_relative "../../gui/immediate_or_cancel"

RSpec.describe RubyCoincheckClient::GUI::ImmediateOrCancel do
  let(:client) { instance_double(RubyCoincheckClient::Client) }
  let(:executor) { described_class.new(client) }
  let(:params) { { pair: "btc_jpy", order_type: "buy", rate: "10000000", amount: "1.0" } }
  let(:detail) do
    { "id" => 42, "pair" => "btc_jpy", "order_type" => "buy", "amount" => "1.0",
      "status" => "PARTIALLY_FILLED_CANCELED", "executed_amount" => "0.25", "expired_amount" => "0" }
  end
  def execute
    executor.call(params, request_id: "ioc-request-123456")
  end

  before do
    allow(client).to receive(:create_order).with(**params).and_return("id" => 42)
    allow(client).to receive(:cancel_order).with(id: "42").and_return("success" => true, "id" => 42)
    allow(client).to receive(:order).with(id: "42").and_return(detail)
  end

  it "cancels immediately before any inspection and reports partial fills exactly" do
    expect(client).to receive(:create_order).with(**params).ordered.and_return("id" => 42)
    expect(client).to receive(:cancel_order).with(id: "42").ordered.and_return("success" => true, "id" => 42)
    expect(client).to receive(:order).with(id: "42").ordered.and_return(detail)
    expect(execute).to include(status: "canceled", terminal: true, executed_amount: "0.25",
                               canceled_amount: "0.75", remaining_amount: "0.0", uncertain: false)
  end

  it "reports a fully filled order even when cancellation is rejected" do
    allow(client).to receive(:cancel_order).and_raise(RubyCoincheckClient::APIError.new("already filled"))
    detail.merge!("status" => "FILLED", "executed_amount" => "1.0")
    expect(execute).to include(status: "filled", executed_amount: "1.0", cancel_request: "rejected", terminal: true)
  end

  it "does not mistake a cancel acknowledgement for a terminal order" do
    detail.merge!("status" => "PARTIALLY_FILLED")
    expect(execute).to include(status: "open", remaining_amount: "0.75", terminal: false, requires_attention: true)
  end

  it "can confirm cancellation after a lost cancellation response" do
    allow(client).to receive(:cancel_order).and_raise(Net::ReadTimeout)
    expect(execute).to include(status: "canceled", cancel_request: "unknown", uncertain: false)
  end

  it "leaves unknown quantities as null when lookup fails, retaining the order ID" do
    allow(client).to receive(:order).and_raise(Net::ReadTimeout)
    expect(execute).to include(status: "unknown", order_id: "42", executed_amount: nil, remaining_amount: nil, uncertain: true)
  end

  it "never retries an ambiguous create or guesses which order to cancel" do
    expect(client).to receive(:create_order).once.and_raise(Net::ReadTimeout)
    expect(client).not_to receive(:cancel_order)
    expect(client).not_to receive(:order)
    expect(execute).to include(status: "unknown", order_id: nil, cancel_request: "not_sent", uncertain: true)
  end

  it "treats missing or malformed order IDs as ambiguous submissions" do
    [nil, "../42", "0"].each do |id|
      allow(client).to receive(:create_order).and_return("id" => id)
      expect(execute).to include(status: "unknown", order_id: nil)
    end
    expect(client).not_to have_received(:cancel_order)
  end

  it "distinguishes a definite exchange rejection" do
    allow(client).to receive(:create_order).and_raise(RubyCoincheckClient::APIError.new("insufficient funds"))
    expect(execute).to include(status: "rejected", terminal: true, uncertain: false)
    expect(client).not_to have_received(:cancel_order)
  end

  it "reports expiry independently from cancellation" do
    detail.merge!("status" => "PARTIALLY_FILLED_EXPIRED", "expired_amount" => "0.75")
    expect(execute).to include(status: "expired", executed_amount: "0.25", expired_amount: "0.75", canceled_amount: "0.0")
  end

  it "rejects inconsistent or mismatched lookup data without inventing fills" do
    [{ "id" => 99 }, { "pair" => "eth_jpy" }, { "amount" => "2.0" },
     { "executed_amount" => "1.1" }, { "executed_amount" => nil },
     { "status" => "FILLED" }, { "status" => "EXPIRED" }, { "status" => "FUTURE_STATUS" }].each do |change|
      allow(client).to receive(:order).and_return(detail.merge(change))
      expect(execute).to include(status: "unknown", executed_amount: nil, uncertain: true)
    end
  end

  it "reconciles unknown results with reads only and preserves terminal results" do
    allow(client).to receive(:order).and_raise(Net::ReadTimeout)
    pending = execute
    allow(client).to receive(:order).and_return(detail)
    resolved = executor.refresh(pending)
    expect(resolved[:status]).to eq("canceled")
    expect(executor.refresh(resolved)).to eq(resolved)
    expect(client).to have_received(:create_order).once
    expect(client).to have_received(:cancel_order).once
    expect(client).to have_received(:order).twice
  end
end
