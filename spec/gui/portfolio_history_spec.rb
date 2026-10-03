# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../../gui/portfolio_history"

RSpec.describe RubyCoincheckClient::GUI::PortfolioHistory do
  let(:now) { [1_800_000_000] }
  let(:directory) { @directory }
  let(:store) { described_class.new(directory: directory, clock: -> { now.first }) }
  let(:portfolio) { { total_jpy: "123456.789", missing_rates: [] } }

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      example.run
    end
  end

  before { store.select_account("account-one") }

  it "persists exact decimal valuations across restart without storing credentials or holdings" do
    store.record(portfolio.merge(api_key: "never-write-me", assets: [{ currency: "btc" }]))
    file = Dir[File.join(directory, "*.json")].fetch(0)
    expect(File.stat(file).mode & 0o777).to eq(0o600)
    expect(File.read(file)).not_to include("account-one", "never-write-me", "btc")
    fresh = described_class.new(directory: directory, clock: -> { now.first })
    fresh.select_account("account-one")
    expect(fresh.points).to eq([{ "at" => now.first, "total_jpy" => "123456.789" }])
  end

  it "samples at most once every five minutes, including after a restart" do
    store.record(portfolio)
    now[0] += 299
    store.select_account("account-one")
    store.record(portfolio)
    expect(store.points.size).to eq(1)
    now[0] += 1
    store.record(portfolio)
    expect(store.points.size).to eq(2)
  end

  it "never records partial valuations, but does record a genuine zero balance" do
    store.record(total_jpy: nil, missing_rates: ["btc"])
    expect(store.points).to be_empty
    store.record(total_jpy: "0", missing_rates: [])
    expect(store.points.first.fetch("total_jpy")).to eq("0.0")
  end

  it "isolates histories when switching keys and hides history when disconnected" do
    store.record(portfolio)
    store.select_account("account-two")
    expect(store.points).to be_empty
    store.record(total_jpy: "50", missing_rates: [])
    store.select_account(nil)
    expect(store.points).to be_empty
    store.select_account("account-one")
    expect(store.points.first.fetch("total_jpy")).to eq("123456.789")
  end

  it "filters periods and prunes data older than thirty days on recording" do
    store.record(portfolio)
    now[0] += 2 * 86_400
    store.record(portfolio)
    expect(store.points.size).to eq(1)
    expect(store.points(days: 7).size).to eq(2)
    now[0] += 29 * 86_400
    store.record(portfolio)
    expect(store.points(days: 30).size).to eq(2)
    file = Dir[File.join(directory, "*.json")].fetch(0)
    expect(JSON.parse(File.read(file)).fetch("samples").size).to eq(2)
  end

  it "does not overwrite a corrupt history file" do
    store.record(portfolio)
    file = Dir[File.join(directory, "*.json")].fetch(0)
    File.write(file, "broken history")
    store.select_account("account-one")
    now[0] += 300
    expect { store.record(portfolio) }.to raise_error(JSON::ParserError)
    expect(File.read(file)).to eq("broken history")
  end
end
