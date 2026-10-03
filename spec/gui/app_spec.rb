# frozen_string_literal: true

require "spec_helper"
require "rack/mock"
require "tmpdir"
require_relative "../../gui/app"

RSpec.describe RubyCoincheckClient::GUI::App do
  let(:client) { RubyCoincheckClient::Client.new("key", "secret") }
  let(:password) { "local-gui-test-password" }
  let(:app) { described_class.new(login_password: password, client: client, authenticated: true) }
  let(:request) { Rack::MockRequest.new(app) }
  let(:bare_host) { { "HTTP_HOST" => "127.0.0.1:9292" } }
  let(:host) { bare_host.merge("HTTP_COOKIE" => login_cookie) }
  let(:token) { JSON.parse(request.get("/api/session", host).body).fetch("token") }
  let(:headers) { host.merge("HTTP_X_LOCAL_TOKEN" => token, "HTTP_ORIGIN" => "http://127.0.0.1:9292", "CONTENT_TYPE" => "application/json") }
  let(:order) { { request_id: "test-request-123456", pair: "btc_jpy", order_type: "buy", rate: "10000000", amount: "0.001" } }

  def login_cookie(mock = request)
    response = mock.post("/api/login", bare_host.merge(
      "HTTP_ORIGIN" => "http://127.0.0.1:9292", "CONTENT_TYPE" => "application/json",
      input: JSON.generate(password: password)
    ))
    response["set-cookie"].split(";").first
  end

  def submit(body = order, path: "/api/orders", extra: {})
    request.post(path, headers.merge(input: JSON.generate(body)).merge(extra))
  end

  it "serves the dashboard and exposes only a local token and credential availability" do
    expect(request.get("/", host).status).to eq(200)
    session = JSON.parse(request.get("/api/session", host).body)
    expect(session.keys.sort).to eq(%w[authenticated token])
    expect(request.get("/", host)["content-security-policy"]).to include("frame-ancestors 'none'")
  end

  it "rejects rebinding, cross-origin writes and missing tokens before reaching Coincheck" do
    expect(client).not_to receive(:create_order)
    expect(request.get("/api/session", "HTTP_HOST" => "evil.example:9292").status).to eq(403)
    expect(submit(extra: { "HTTP_ORIGIN" => "https://evil.example" }).status).to eq(403)
    expect(submit(extra: { "HTTP_X_LOCAL_TOKEN" => nil }).status).to eq(403)
    expect(submit(extra: { "CONTENT_TYPE" => "text/plain" }).status).to eq(400)
  end

  it "requires a same-origin token on streaming connections" do
    expect(request.get("/stream?pair=btc_jpy", host).status).to eq(403)
    expect(request.get("/stream?pair=btc_jpy", host.merge("HTTP_ORIGIN" => "https://evil.example", "HTTP_SEC_WEBSOCKET_PROTOCOL" => "coincheck-local, #{token}")).status).to eq(403)
  end

  it "allows public data without credentials but rejects account access" do
    app = described_class.new(login_password: password, client: client, authenticated: false)
    mock = Rack::MockRequest.new(app)
    local_host = bare_host.merge("HTTP_COOKIE" => login_cookie(mock))
    token = JSON.parse(mock.get("/api/session", local_host).body)["token"]
    expect(client).to receive(:ticker).with(pair: "btc_jpy").and_return("last" => 100)
    expect(mock.get("/api/ticker", local_host.merge("HTTP_X_LOCAL_TOKEN" => token)).status).to eq(200)
    expect(mock.get("/api/balance", local_host.merge("HTTP_X_LOCAL_TOKEN" => token)).status).to eq(401)
  end

  it "submits a confirmed order once even when a browser repeats the request" do
    expect(client).to receive(:create_order).with(pair: "btc_jpy", order_type: "buy", rate: "10000000", amount: "0.001").once.and_return("id" => 42)
    first = submit
    second = submit
    expect(first.status).to eq(200)
    expect(second.body).to eq(first.body)
    expect(submit(order.merge(amount: "0.002")).status).to eq(409)
  end

  it "never resends an order whose response was lost" do
    expect(client).to receive(:create_order).once.and_raise(Net::ReadTimeout)
    first = submit
    expect(first.status).to eq(502)
    expect(JSON.parse(first.body)["uncertain"]).to eq(true)
    expect(submit.body).to eq(first.body)
  end

  it "treats even an HTTP failure as uncertain, since a write might have committed" do
    stub_request(:post, "https://coincheck.com/api/exchange/orders").to_return(status: 503, body: "Unavailable")
    expect(JSON.parse(submit.body)["uncertain"]).to eq(true)
  end

  it "rejects missing, non-positive and malformed order amounts locally" do
    expect(client).not_to receive(:create_order)
    ["0", "-1", "NaN", "1e9", 10, nil].each do |value|
      expect(submit(order.merge(amount: value)).status).to eq(400)
    end
    expect(submit(order.reject { |key, _| key == :amount }).status).to eq(400)
    expect(submit(order.merge(pair: "../secrets")).status).to eq(400)
    expect(submit(order.merge(unknown: true)).status).to eq(400)
  end

  it "supports market orders and idempotent cancellation" do
    expect(client).to receive(:create_order).with(pair: "btc_jpy", order_type: "market_buy", market_buy_amount: "10000").and_return("id" => 43)
    expect(submit({ request_id: "market-request-12345", pair: "btc_jpy", order_type: "market_buy", market_buy_amount: "10000" }).status).to eq(200)
    expect(client).to receive(:cancel_order).with(id: "43").once.and_return("success" => true)
    2.times { expect(submit({ request_id: "cancel-request-12345" }, path: "/api/orders/43/cancel").status).to eq(200) }
  end

  it "forwards pagination and filters orders for the selected pair" do
    expect(client).to receive(:transactions_pagination).with(limit: 25, order: "desc", starting_after: "99").and_return("data" => [])
    expect(request.get("/api/transactions?starting_after=99", headers).status).to eq(200)
    expect(client).to receive(:orders).with(pair: "eth_jpy").and_return("orders" => [])
    expect(request.get("/api/orders?pair=eth_jpy", headers).status).to eq(200)
  end

  it "returns a JPY portfolio valuation to the logged-in account" do
    expect(client).to receive(:balance).and_return("jpy" => "1000", "eth" => "0.5", "eth_reserved" => "0.1")
    stub_request(:get, "https://coincheck.com/api/rate/eth_jpy").to_return(body: '{"rate":"400000"}')
    response = request.get("/api/portfolio", headers)
    expect(response.status).to eq(200)
    expect(JSON.parse(response.body)["total_jpy"]).to eq("241000.0")
  end

  it "does not expose arbitrary local files" do
    expect(request.get("/.env", headers).status).to eq(404)
    expect(request.get("/../Gemfile", headers).status).to eq(404)
  end

  it "records a registered account in the background without an open browser" do
    Dir.mktmpdir do |directory|
      app = described_class.new(login_password: password, authenticated: false, history_directory: directory)
      mock = Rack::MockRequest.new(app)
      cookie = login_cookie(mock)
      local_host = bare_host.merge("HTTP_COOKIE" => cookie)
      local_token = JSON.parse(mock.get("/api/session", local_host).body).fetch("token")
      local_headers = headers.merge(local_host).merge("HTTP_X_LOCAL_TOKEN" => local_token)
      stub_request(:get, "https://coincheck.com/api/accounts/balance").to_return(body: '{"jpy":"1000"}')
      response = mock.post("/api/credentials", local_headers.merge(input: JSON.generate(api_key: "history-key", api_secret: "secret")))
      local_headers["HTTP_X_LOCAL_TOKEN"] = JSON.parse(response.body).fetch("token")
      begin
        app.start_monitoring
        Timeout.timeout(3) do
          sleep 0.01 until Dir[File.join(directory, "*.json")].any?
        end
        data = JSON.parse(mock.get("/api/portfolio/history?days=7", local_headers).body)
        expect(data.fetch("points").first.fetch("total_jpy")).to eq("1000.0")
        expect(mock.get("/api/portfolio/history?days=2", local_headers).status).to eq(400)
        expect(mock.get("/api/portfolio/history", bare_host).status).to eq(401)
      ensure
        app.stop_monitoring
      end
    end
  end

  %w[btc_jpy eth_jpy xrp_jpy sol_jpy].each do |pair|
    it "routes market data, open orders and new orders for #{pair}" do
      { ticker: "ticker", order_book: "book", trades: "trades", orders: "orders" }.each do |method, path|
        options = { pair: pair }
        options.merge!(limit: 50, order: "desc") if method == :trades
        expect(client).to receive(method).with(**options).and_return({})
        expect(request.get("/api/#{path}?pair=#{pair}", headers).status).to eq(200)
      end
      expect(client).to receive(:create_order).with(pair: pair, order_type: "buy", rate: "10000000", amount: "0.001").and_return("id" => 10)
      expect(submit(order.merge(pair: pair)).status).to eq(200)
    end
  end

  describe "credential registration" do
    let(:credentials) { { api_key: "new-key", api_secret: "new-secret" } }

    def accept_credentials
      stub_request(:get, "https://coincheck.com/api/accounts/balance")
        .with(headers: { "ACCESS-KEY" => "new-key" })
        .to_return(body: '{"success":true,"jpy":"1000"}')
    end

    it "checks credentials read-only, rotates the session, and never returns the key" do
      accept_credentials
      response = submit(credentials, path: "/api/credentials")
      expect(response.status).to eq(200)
      data = JSON.parse(response.body)
      expect(data["authenticated"]).to eq(true)
      expect(data["token"]).not_to eq(token)
      expect(response.body).not_to include("new-key", "new-secret")
      expect(submit.status).to eq(403)
      expect(request.get("/api/balance", headers.merge("HTTP_X_LOCAL_TOKEN" => data["token"])).status).to eq(200)
      expect(JSON.parse(request.get("/api/session", host).body)).to eq(data)
    end

    it "allows registration when no key was configured at startup" do
      app = described_class.new(login_password: password, client: client, authenticated: false)
      mock = Rack::MockRequest.new(app)
      local_host = bare_host.merge("HTTP_COOKIE" => login_cookie(mock))
      token = JSON.parse(mock.get("/api/session", local_host).body)["token"]
      accept_credentials
      response = mock.post("/api/credentials", headers.merge(local_host).merge("HTTP_X_LOCAL_TOKEN" => token, input: JSON.generate(credentials)))
      expect(response.status).to eq(200)
      expect(JSON.parse(response.body)["authenticated"]).to eq(true)
    end

    it "preserves the previous account and hides upstream text if validation fails" do
      stub_request(:get, "https://coincheck.com/api/accounts/balance")
        .with(headers: { "ACCESS-KEY" => "new-key" })
        .to_return(status: 401, body: '{"error":"rejected new-key new-secret"}')
      response = submit(credentials, path: "/api/credentials")
      expect(response.status).to eq(422)
      expect(response.body).not_to include("new-key", "new-secret")
      expect(client).to receive(:balance).and_return("success" => true)
      expect(request.get("/api/balance", headers).status).to eq(200)
      expect(JSON.parse(request.get("/api/session", host).body)["token"]).to eq(token)
    end

    it "rejects invalid values, missing tokens, and cross-origin registration" do
      [nil, "", "bad\nkey", "x" * 513, 123].each do |value|
        expect(submit(credentials.merge(api_key: value), path: "/api/credentials").status).to eq(400)
      end
      expect(submit(credentials, path: "/api/credentials", extra: { "HTTP_X_LOCAL_TOKEN" => "wrong" }).status).to eq(403)
      expect(submit(credentials, path: "/api/credentials", extra: { "HTTP_ORIGIN" => "https://evil.example" }).status).to eq(403)
    end

    it "removes credentials, revokes old tokens, and retains public access" do
      response = submit({}, path: "/api/credentials/clear")
      data = JSON.parse(response.body)
      expect(data["authenticated"]).to eq(false)
      expect(request.get("/api/balance", headers).status).to eq(403)
      fresh = headers.merge("HTTP_X_LOCAL_TOKEN" => data["token"])
      expect(request.get("/api/balance", fresh).status).to eq(401)
      stub_request(:get, "https://coincheck.com/api/ticker?pair=sol_jpy").to_return(body: '{"last":20000}')
      expect(request.get("/api/ticker?pair=sol_jpy", fresh).status).to eq(200)
    end

    it "does not replay the previous account's cached mutation response" do
      expect(client).to receive(:create_order).once.and_return("id" => 1234)
      expect(submit.status).to eq(200)
      accept_credentials
      data = JSON.parse(submit(credentials, path: "/api/credentials").body)
      response = submit(extra: { "HTTP_X_LOCAL_TOKEN" => data["token"] })
      expect(response.status).to eq(409)
      expect(response.body).not_to include("1234")
    end

    it "closes the previous account's streams and suppresses late messages" do
      handlers = {}
      server_socket = double("local socket", rack_response: [-1, {}, []])
      allow(server_socket).to receive(:on) { |event, &handler| handlers[event] = handler }
      allow(server_socket).to receive(:close) { handlers[:close].call(nil) }
      allow(server_socket).to receive(:send)
      allow(Faye::WebSocket).to receive(:websocket?).and_return(true)
      allow(Faye::WebSocket).to receive(:new).and_return(server_socket)
      allow(EventMachine).to receive(:add_timer).and_return(888)
      allow(EventMachine).to receive(:cancel_timer)
      subscriptions = []
      connection = double("upstream", start: nil, stop: nil)
      allow(RubyCoincheckClient::WebSocket).to receive(:new) { |**options| subscriptions << options; connection }
      env = Rack::MockRequest.env_for("/stream?pair=eth_jpy", headers.merge("HTTP_SEC_WEBSOCKET_PROTOCOL" => "coincheck-local, #{token}"))
      expect(app.call(env).first).to eq(-1)
      handlers[:open].call(nil)
      expect(subscriptions.size).to eq(2)
      expect(subscriptions.first[:pair]).to eq("eth_jpy")
      allow(EventMachine).to receive(:reactor_running?).and_return(true)
      allow(EventMachine).to receive(:schedule).and_yield
      accept_credentials
      expect(submit(credentials, path: "/api/credentials").status).to eq(200)
      expect(server_socket).to have_received(:close).once
      expect(connection).to have_received(:stop).twice
      subscriptions.last[:on_message].call("channel" => "order-events", "id" => "old-account")
      expect(server_socket).to have_received(:send).with(JSON.generate(type: "session_changed")).once
      expect(server_socket).to have_received(:send).once
      expect { subscriptions.last[:login].call }.to raise_error(RubyCoincheckClient::ConfigurationError)
    end
  end
end
