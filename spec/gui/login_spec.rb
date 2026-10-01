# frozen_string_literal: true

require "spec_helper"
require "rack/mock"
require_relative "../../gui/app"

RSpec.describe "GUI login boundary" do
  let(:password) { "local-test-password-123" }
  let(:clock) { [100.0] }
  let(:client) { instance_double(RubyCoincheckClient::Client) }
  let(:app) { RubyCoincheckClient::GUI::App.new(login_password: password, client: client, authenticated: true, clock: -> { clock.first }) }
  let(:request) { Rack::MockRequest.new(app) }
  let(:host) { { "HTTP_HOST" => "127.0.0.1:9292" } }
  let(:json_headers) { host.merge("HTTP_ORIGIN" => "http://127.0.0.1:9292", "CONTENT_TYPE" => "application/json") }

  def login(value = password, extra = {})
    request.post("/api/login", json_headers.merge(input: JSON.generate(password: value)).merge(extra))
  end

  def authenticated_headers
    cookie = login["set-cookie"].split(";").first
    headers = json_headers.merge("HTTP_COOKIE" => cookie)
    token = JSON.parse(request.get("/api/session", headers).body).fetch("token")
    headers.merge("HTTP_X_LOCAL_TOKEN" => token)
  end

  it "shows a login page and withholds tokens and account data from a local unauthenticated process" do
    expect(request.get("/", host).body).to include('id="login-form"')
    %w[/api/session /api/balance /api/portfolio /api/orders /api/transactions /api/ticker /stream].each do |path|
      response = request.get(path, host)
      expect(response.status).to eq(401)
      expect(JSON.parse(response.body)).not_to have_key("token")
    end
    %w[/api/credentials /api/credentials/clear /api/orders /api/orders/123/cancel /api/logout].each do |path|
      expect(request.post(path, json_headers.merge(input: "{}")).status).to eq(401)
    end
  end

  it "uses an HttpOnly SameSite cookie and requires both the cookie and action token" do
    response = login
    expect(response.status).to eq(200)
    expect(response["set-cookie"]).to include("httponly", "samesite=strict", "path=/")
    expect(response.body).not_to include(password, "token")
    headers = authenticated_headers
    expect(request.get("/", headers).body).to include('id="balances"')
    expect(request.post("/api/orders", headers.merge("HTTP_COOKIE" => nil, input: "{}")).status).to eq(401)
    expect(request.post("/api/orders", headers.merge("HTTP_X_LOCAL_TOKEN" => nil, input: "{}")).status).to eq(403)
  end

  it "rejects cross-origin and non-JSON login attempts" do
    expect(login(password, "HTTP_ORIGIN" => "https://evil.example").status).to eq(403)
    expect(login(password, "HTTP_ORIGIN" => nil).status).to eq(403)
    expect(login(password, "CONTENT_TYPE" => "text/plain").status).to eq(400)
  end

  it "rate limits guessing without exposing any action token" do
    5.times { expect(login("incorrect").status).to eq(401) }
    response = login
    expect(response.status).to eq(429)
    expect(response["retry-after"]).to eq("60")
    expect(response["set-cookie"]).to be_nil
  end

  it "revokes cookies on logout and expiry, including the old action token" do
    headers = authenticated_headers
    response = request.post("/api/logout", headers.merge(input: "{}"))
    expect(response.status).to eq(200)
    expect(response["set-cookie"]).to include("max-age=0")
    expect(request.get("/api/session", headers).status).to eq(401)
    expect(request.post("/api/orders", headers.merge(input: "{}")).status).to eq(401)
    fresh = authenticated_headers
    clock[0] += RubyCoincheckClient::GUI::Auth::SESSION_SECONDS
    expect(request.get("/api/session", fresh).status).to eq(401)
    expect(request.post("/api/orders", fresh.merge(input: "{}")).status).to eq(401)
  end

  it "rejects unauthenticated WebSockets even when the action token is known" do
    headers = authenticated_headers
    env = host.merge("HTTP_ORIGIN" => "http://127.0.0.1:9292", "HTTP_SEC_WEBSOCKET_PROTOCOL" => "coincheck-local, #{headers['HTTP_X_LOCAL_TOKEN']}")
    expect(Faye::WebSocket).not_to receive(:new)
    expect(request.get("/stream", env).status).to eq(401)
  end

  it "closes existing streams on logout and blocks late account events" do
    headers = authenticated_headers
    handlers = {}
    socket = double("socket", rack_response: [-1, {}, []])
    allow(socket).to receive(:on) { |name, &block| handlers[name] = block }
    allow(socket).to receive(:send)
    allow(socket).to receive(:close) { handlers[:close].call(nil) }
    allow(Faye::WebSocket).to receive(:new).and_return(socket)
    allow(Faye::WebSocket).to receive(:websocket?).and_return(true)
    allow(EventMachine).to receive(:add_timer).and_return(888)
    allow(EventMachine).to receive(:cancel_timer)
    subscriptions = []
    upstream = double("upstream", start: nil, stop: nil)
    allow(RubyCoincheckClient::WebSocket).to receive(:new) { |**options| subscriptions << options; upstream }
    env = Rack::MockRequest.env_for("/stream", headers.merge("HTTP_SEC_WEBSOCKET_PROTOCOL" => "coincheck-local, #{headers['HTTP_X_LOCAL_TOKEN']}"))
    app.call(env)
    handlers[:open].call(nil)
    allow(EventMachine).to receive(:reactor_running?).and_return(true)
    allow(EventMachine).to receive(:schedule).and_yield
    expect(request.post("/api/logout", headers.merge(input: "{}")).status).to eq(200)
    expect(socket).to have_received(:send).with(JSON.generate(type: "login_required")).once
    expect(socket).to have_received(:close).once
    expect(upstream).to have_received(:stop).twice
    subscriptions.last[:on_message].call("channel" => "execution-events")
    expect(socket).to have_received(:send).once
  end
end
