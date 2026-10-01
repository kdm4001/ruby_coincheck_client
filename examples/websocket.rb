#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/ruby_coincheck_client/websocket"

EventMachine.run do
  stream = RubyCoincheckClient::WebSocket.new(
    pair: "btc_jpy",
    on_message: ->(message) { puts JSON.generate(message) },
    on_status: ->(status) { warn status.inspect }
  ).start
  %w[INT TERM].each do |signal|
    Signal.trap(signal) { EventMachine.schedule { stream.stop; EventMachine.stop } }
  end
end
