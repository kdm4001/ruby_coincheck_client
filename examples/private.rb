#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/ruby_coincheck_client'

client = RubyCoincheckClient::Client.new(
  ENV.fetch("COINCHECK_API_KEY"),
  ENV.fetch("COINCHECK_API_SECRET")
)

puts client.balance
puts client.account
puts client.transactions
puts client.transactions_pagination(limit: 25, order: "desc")
