#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/ruby_coincheck_client'

client = RubyCoincheckClient::Client.new
puts client.ticker
puts client.trades
puts client.rate
puts client.order_book
puts client.order_rate(order_type: "sell", price: 100_000)
