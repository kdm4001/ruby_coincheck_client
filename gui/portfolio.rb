# frozen_string_literal: true

require "bigdecimal"
require "time"
require_relative "../lib/ruby_coincheck_client"

module RubyCoincheckClient
  module GUI
    # Valuation uses public reference rates, never an executable order quote.
    class Portfolio
      DISPLAY_CURRENCIES = %w[jpy btc eth xrp sol].freeze
      ASSET_FIELDS = %w[available reserved lending lend_in_use lent tsumitate].freeze
      RATE_TTL = 20

      def initialize(rate_client: Client.new(open_timeout: 1, read_timeout: 2),
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @rate_client = rate_client
        @clock = clock
        @rates = {}
        @mutex = Mutex.new
      end

      def call(balance)
        amounts = Hash.new { |hash, currency| hash[currency] = Hash.new(BigDecimal("0")) }
        balance.each do |key, value|
          next if key == "success"
          match = /\A([a-z0-9]+)(?:_(reserved|lending|lend_in_use|lent|debt|tsumitate))?\z/.match(key)
          next unless match

          amounts[match[1]][match[2] || "available"] = decimal(value)
        end
        DISPLAY_CURRENCIES.each { |currency| amounts[currency] }
        rows = amounts.filter_map do |currency, components|
          next if components.values.all?(&:zero?) && !DISPLAY_CURRENCIES.include?(currency)

          holdings = ASSET_FIELDS.sum(BigDecimal("0")) { |field| components[field] } - components["debt"]
          other = %w[lending lend_in_use lent tsumitate].sum(BigDecimal("0")) { |field| components[field] }
          { currency: currency, available: components["available"], reserved: components["reserved"],
            other: other, debt: components["debt"], quantity: holdings }
        end
        rates = fetch_rates(rows.reject { |row| row[:currency] == "jpy" || row[:quantity].zero? }.map { |row| row[:currency] })
        missing = []
        valued = BigDecimal("0")
        assets = rows.map do |row|
          currency = row[:currency]
          rate = currency == "jpy" ? BigDecimal("1") : rates[currency]
          yen = row[:quantity].zero? ? BigDecimal("0") : rate && row[:quantity] * rate
          missing << currency unless yen
          valued += yen if yen
          row.transform_values { |value| value.is_a?(BigDecimal) ? value.to_s("F") : value }
             .merge(rate: rate&.to_s("F"), value_jpy: yen&.to_s("F"))
        end
        assets.sort_by! { |row| [DISPLAY_CURRENCIES.index(row[:currency]) || DISPLAY_CURRENCIES.size, row[:currency]] }
        { assets: assets, total_jpy: missing.empty? ? valued.to_s("F") : nil,
          valued_jpy: valued.to_s("F"), missing_rates: missing, updated_at: Time.now.utc.iso8601 }
      end

      private

      def decimal(value)
        text = value.to_s
        raise ResponseError, "残高・レートの数値を読み取れませんでした" unless /\A-?\d+(?:\.\d+)?\z/.match?(text)
        BigDecimal(text)
      end

      def fetch_rates(currencies)
        queue = Queue.new
        currencies.each { |currency| queue << currency }
        result = {}
        # Bound concurrency and overall work when many assets lack a quote.
        # Unpriced holdings stay unvalued instead of silently becoming zero.
        deadline = @clock.call + 4
        workers = [currencies.size, 4].min.times.map do
          Thread.new do
            loop do
              break if @clock.call >= deadline
              currency = begin
                queue.pop(true)
              rescue ThreadError
                break
              end
              rate = rate_for(currency)
              @mutex.synchronize { result[currency] = rate } if rate
            end
          end
        end
        workers.each(&:join)
        result
      end

      def rate_for(currency)
        cached = @mutex.synchronize { @rates[currency] }
        return cached[:rate] if cached && @clock.call - cached[:at] < RATE_TTL

        rate = decimal(@rate_client.rate(pair: "#{currency}_jpy").fetch("rate"))
        return nil unless rate.positive?
        @mutex.synchronize { @rates[currency] = { rate: rate, at: @clock.call } }
        rate
      rescue RubyCoincheckClient::Error, IOError, SystemCallError, Timeout::Error,
             SocketError, OpenSSL::SSL::SSLError, KeyError, TypeError
        nil
      end
    end
  end
end
