# frozen_string_literal: true

require "spec_helper"
require "ostruct"
require "ruby_coincheck_client/websocket"

RSpec.describe RubyCoincheckClient::WebSocket do
  class FakeWebSocket
    attr_reader :sent
    def initialize
      @handlers = {}
      @sent = []
    end
    def on(name, &handler) = @handlers[name] = handler
    def fire(name, data = nil) = @handlers[name]&.call(OpenStruct.new(data: data))
    def send(data) = @sent << JSON.parse(data)
    def close = fire(:close)
    def ready_state = Faye::WebSocket::API::OPEN
  end

  let(:socket) { FakeWebSocket.new }
  let(:statuses) { [] }
  let(:messages) { [] }
  let(:timer) { 123 }
  let(:client) { RubyCoincheckClient::Client.new("key", "secret", nonce_generator: -> { 1000 }) }

  before do
    allow(Faye::WebSocket::Client).to receive(:new).and_return(socket)
    allow(EventMachine).to receive(:add_timer).and_return(timer)
    allow(EventMachine).to receive(:cancel_timer)
    allow(EventMachine).to receive(:defer) { |operation, callback| callback.call(operation.call) }
  end

  def stream(**options)
    described_class.new(on_message: ->(message) { messages << message }, on_status: ->(status) { statuses << status }, **options)
  end

  it "subscribes to both public channels and forwards documented batched trades unchanged" do
    connection = stream(pair: "eth_jpy").start
    socket.fire(:open)
    expect(socket.sent).to eq([
      { "type" => "subscribe", "channel" => "eth_jpy-trades" },
      { "type" => "subscribe", "channel" => "eth_jpy-orderbook" }
    ])
    payload = [["1663318663", "2357062", "eth_jpy", "2820896.0", "5.0", "sell"]]
    socket.fire(:message, JSON.generate(payload))
    expect(messages).to eq([payload])
    expect(statuses.last[:state]).to eq("connected")
    expect(EventMachine).to have_received(:cancel_timer).with(timer)
    connection.stop
  end

  it "signs the fixed private URI and shares nonce ordering with REST" do
    stub_request(:get, "https://coincheck.com/api/accounts/balance").to_return(body: '{"success":true}')
    client.balance
    connection = stream(private_stream: true, client: client).start
    socket.fire(:open)
    login = socket.sent.first
    expect(login["access_nonce"]).to eq("1001")
    expect(login["access_signature"]).to eq(OpenSSL::HMAC.hexdigest("SHA256", "secret", "1001wss://stream.coincheck.com/private"))
    expect(socket.sent.length).to eq(1)
    socket.fire(:message, '{"success":true,"available_channels":["order-events"]}')
    expect(socket.sent.last).to eq("type" => "subscribe", "channels" => ["order-events"])
    expect(statuses.last[:channels]).to eq(["order-events"])
    expect(messages).to be_empty
    connection.stop
  end

  it "stops on rejected authentication without disclosing the server response" do
    connection = stream(private_stream: true, client: client).start
    socket.fire(:open)
    socket.fire(:message, '{"success":false,"error":"sensitive payload"}')
    expect(statuses.last[:state]).to eq("error")
    expect(statuses.to_s).not_to include("sensitive payload")
    expect(messages).to be_empty
    connection.stop
  end

  it "backs off and resubscribes after disconnection, but not after stop" do
    retries = []
    allow(EventMachine).to receive(:add_timer) { |delay, &block| retries << [delay, block]; timer }
    connection = stream.start
    socket.fire(:close)
    expect(retries.last.first).to eq(1)
    retries.last.last.call
    socket.fire(:close)
    expect(retries.last.first).to eq(2)
    retries.last.last.call
    socket.fire(:open)
    expect(socket.sent.last["channel"]).to eq("btc_jpy-orderbook")
    expect(statuses.last[:state]).to eq("connected")
    connection.stop
    expect(statuses.last[:state]).to eq("connected")
  end

  it "reports malformed JSON and reconnects" do
    connection = stream.start
    socket.fire(:message, "not json")
    expect(statuses.map { |status| status[:state] }).to include("error", "reconnecting")
    connection.stop
  end

  it "retries failures that close the client before handlers are installed" do
    allow(socket).to receive(:ready_state).and_return(Faye::WebSocket::API::CLOSED)
    connection = stream.start
    expect(statuses.last).to include(state: "reconnecting", retry_in: 1)
    connection.stop
  end
end
