# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "thread"
require "uri"

require_relative "errors"
require_relative "version"

module RubyCoincheckClient
  class Client
    BASE_URL = "https://coincheck.com/"
    ORDER_TYPES = %w[buy sell market_buy market_sell].freeze
    DEFAULT_OPEN_TIMEOUT = 10
    DEFAULT_READ_TIMEOUT = 30

    attr_reader :base_url

    def initialize(
      key = nil,
      secret = nil,
      options = nil,
      base_url: BASE_URL,
      open_timeout: DEFAULT_OPEN_TIMEOUT,
      read_timeout: DEFAULT_READ_TIMEOUT,
      verify_ssl: true,
      nonce_generator: nil
    )
      if options
        raise ArgumentError, "options must be a Hash" unless options.is_a?(Hash)

        base_url = options.fetch(:base_url, base_url)
        open_timeout = options.fetch(:open_timeout, open_timeout)
        read_timeout = options.fetch(:read_timeout, read_timeout)
        verify_ssl = options.fetch(:verify_ssl, options.fetch(:ssl, verify_ssl))
        nonce_generator = options.fetch(:nonce_generator, nonce_generator)
      end

      @key = key
      @secret = secret
      @base_url = normalize_base_url(base_url)
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @verify_ssl = verify_ssl
      @nonce_generator = nonce_generator || -> { (Time.now.to_f * 1_000).to_i }
      @nonce_mutex = Mutex.new
      @last_nonce = 0
    end

    # Public API

    def ticker(pair: "btc_jpy")
      get("api/ticker", query: { pair: pair })
    end

    def trades(pair: "btc_jpy", **pagination)
      get("api/trades", query: pagination.merge(pair: pair))
    end

    def order_book(pair: "btc_jpy")
      get("api/order_books", query: { pair: pair })
    end

    def order_rate(order_type:, pair: "btc_jpy", price: nil, amount: nil)
      raise ArgumentError, "price or amount is required" if price.nil? && amount.nil?

      get(
        "api/exchange/orders/rate",
        query: { order_type: order_type, pair: pair, price: price, amount: amount }
      )
    end

    def rate(pair: "btc_jpy")
      get("api/rate/#{escape_path(pair)}")
    end

    def exchange_status(pair: nil)
      get("api/exchange_status", query: { pair: pair })
    end

    # Private API: orders

    def create_order(
      order_type:,
      pair: "btc_jpy",
      rate: nil,
      amount: nil,
      market_buy_amount: nil,
      stop_loss_rate: nil,
      time_in_force: nil
    )
      order_type = order_type.to_s
      validate_order!(order_type, rate: rate, amount: amount, market_buy_amount: market_buy_amount)

      post(
        "api/exchange/orders",
        authenticated: true,
        body: {
          pair: pair,
          order_type: order_type,
          rate: rate,
          amount: amount,
          market_buy_amount: market_buy_amount,
          stop_loss_rate: stop_loss_rate,
          time_in_force: time_in_force
        }
      )
    end

    def order(id:)
      get("api/exchange/orders/#{escape_path(id)}", authenticated: true)
    end

    def orders(pair: nil)
      response = get("api/exchange/orders/opens", authenticated: true)
      return response unless pair

      response.merge("orders" => response.fetch("orders", []).select { |item| item["pair"] == pair })
    end

    def cancel_order(id:)
      delete("api/exchange/orders/#{escape_path(id)}", authenticated: true)
    end

    def cancel_status(id:)
      get("api/exchange/orders/cancel_status", authenticated: true, query: { id: id })
    end

    def cancel_all_orders(pair: nil)
      orders(pair: pair).fetch("orders", []).map { |item| cancel_order(id: item.fetch("id")) }
    end

    def transactions
      get("api/exchange/orders/transactions", authenticated: true)
    end

    def transactions_pagination(limit: nil, order: nil, starting_after: nil, ending_before: nil)
      get(
        "api/exchange/orders/transactions_pagination",
        authenticated: true,
        query: pagination_params(limit, order, starting_after, ending_before)
      )
    end

    # Private API: account and transfers

    def balance
      get("api/accounts/balance", authenticated: true)
    end

    def account
      get("api/accounts", authenticated: true)
    end

    def send_money(remittee_list_id:, amount:, purpose_type:, purpose_details: nil)
      post(
        "api/send_money",
        authenticated: true,
        body: {
          remittee_list_id: remittee_list_id,
          amount: amount,
          purpose_type: purpose_type,
          purpose_details: purpose_details
        }
      )
    end

    def send_money_history(currency: "BTC")
      get("api/send_money", authenticated: true, query: { currency: currency })
    end

    def deposits(currency: "BTC")
      get("api/deposit_money", authenticated: true, query: { currency: currency })
    end

    # Private API: JPY withdrawals

    def bank_accounts
      get("api/bank_accounts", authenticated: true)
    end

    def create_bank_account(bank_name:, branch_name:, bank_account_type:, number:, name:)
      post(
        "api/bank_accounts",
        authenticated: true,
        body: {
          bank_name: bank_name,
          branch_name: branch_name,
          bank_account_type: bank_account_type,
          number: number,
          name: name
        }
      )
    end

    def delete_bank_account(id:)
      delete("api/bank_accounts/#{escape_path(id)}", authenticated: true)
    end

    def withdraws(limit: nil, order: nil, starting_after: nil, ending_before: nil)
      get(
        "api/withdraws",
        authenticated: true,
        query: pagination_params(limit, order, starting_after, ending_before)
      )
    end

    def create_withdraw(bank_account_id:, amount:, currency: "JPY")
      post(
        "api/withdraws",
        authenticated: true,
        body: { bank_account_id: bank_account_id, amount: amount, currency: currency }
      )
    end

    def cancel_withdraw(id:)
      delete("api/withdraws/#{escape_path(id)}", authenticated: true)
    end

    # Compatibility aliases for the original API.
    alias read_ticker ticker
    alias read_trades trades
    alias read_all_trades trades
    alias read_order_books order_book
    alias read_orders_rate order_rate
    alias read_rate rate
    alias create_orders create_order
    alias read_orders orders
    alias read_transactions transactions
    alias read_page_transactions transactions_pagination
    alias read_balance balance
    alias read_accounts account
    alias create_send_crypto send_money
    alias read_send_crypto send_money_history
    alias read_deposits deposits
    alias read_bank_accounts bank_accounts
    alias create_bank_accounts create_bank_account
    alias delete_bank_accounts delete_bank_account
    alias read_jpy_withdraws withdraws
    alias create_jpy_withdraw create_withdraw
    alias delete_jpy_withdraws cancel_withdraw

    private

    def get(path, authenticated: false, query: {})
      request(Net::HTTP::Get, path, authenticated: authenticated, query: query)
    end

    def post(path, authenticated: false, body: {})
      request(Net::HTTP::Post, path, authenticated: authenticated, body: body)
    end

    def delete(path, authenticated: false)
      request(Net::HTTP::Delete, path, authenticated: authenticated)
    end

    def request(request_class, path, authenticated:, query: {}, body: nil)
      uri = build_uri(path, query)
      encoded_body = body && JSON.generate(compact_hash(body))
      headers = default_headers
      headers.merge!(authentication_headers(uri, encoded_body.to_s)) if authenticated

      http_request = request_class.new(uri.request_uri, headers)
      http_request.body = encoded_body if encoded_body

      response = perform_request(uri, http_request)
      unless response.is_a?(Net::HTTPSuccess)
        raise HTTPError.new(response, body: parse_error_response(response.body))
      end

      parsed_body = parse_response(response.body)
      raise APIError, parsed_body if parsed_body.is_a?(Hash) && parsed_body["success"] == false

      parsed_body
    end

    def perform_request(uri, request)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE if http.use_ssl? && !@verify_ssl
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout
      http.start { |connection| connection.request(request) }
    end

    def parse_response(body)
      JSON.parse(body)
    rescue JSON::ParserError => error
      raise ResponseError.new("Coincheck API returned invalid JSON: #{error.message}", body: body)
    end

    def parse_error_response(body)
      JSON.parse(body)
    rescue JSON::ParserError
      body
    end

    def authentication_headers(uri, body)
      validate_credentials!
      nonce = next_nonce
      signature = OpenSSL::HMAC.hexdigest("SHA256", @secret, "#{nonce}#{uri}#{body}")

      {
        "ACCESS-KEY" => @key,
        "ACCESS-NONCE" => nonce,
        "ACCESS-SIGNATURE" => signature
      }
    end

    def next_nonce
      @nonce_mutex.synchronize do
        generated = Integer(@nonce_generator.call)
        @last_nonce = [generated, @last_nonce + 1].max
        @last_nonce.to_s
      end
    rescue ArgumentError, TypeError
      raise ConfigurationError, "nonce_generator must return an integer"
    end

    def validate_credentials!
      return unless blank?(@key) || blank?(@secret)

      raise ConfigurationError, "API key and secret are required for private endpoints"
    end

    def validate_order!(order_type, rate:, amount:, market_buy_amount:)
      unless ORDER_TYPES.include?(order_type)
        raise ArgumentError, "order_type must be one of: #{ORDER_TYPES.join(', ')}"
      end

      case order_type
      when "buy", "sell"
        raise ArgumentError, "rate and amount are required for limit orders" if rate.nil? || amount.nil?
      when "market_buy"
        raise ArgumentError, "market_buy_amount is required for market_buy" if market_buy_amount.nil?
      when "market_sell"
        raise ArgumentError, "amount is required for market_sell" if amount.nil?
      end
    end

    def normalize_base_url(value)
      uri = URI.parse(value.to_s)
      unless %w[http https].include?(uri.scheme) && uri.host
        raise ConfigurationError, "base_url must be an absolute HTTP(S) URL"
      end

      uri.path = "#{uri.path}/" unless uri.path.end_with?("/")
      uri.query = nil
      uri.fragment = nil
      uri.to_s
    rescue URI::InvalidURIError
      raise ConfigurationError, "base_url must be an absolute HTTP(S) URL"
    end

    def build_uri(path, query)
      uri = URI.join(@base_url, path)
      compacted_query = compact_hash(query)
      uri.query = URI.encode_www_form(compacted_query) unless compacted_query.empty?
      uri
    end

    def default_headers
      {
        "Accept" => "application/json",
        "Content-Type" => "application/json",
        "User-Agent" => "ruby_coincheck_client/#{VERSION}"
      }
    end

    def compact_hash(hash)
      hash.reject { |_, value| value.nil? }
    end

    def pagination_params(limit, order, starting_after, ending_before)
      {
        limit: limit,
        order: order,
        starting_after: starting_after,
        ending_before: ending_before
      }
    end

    def escape_path(value)
      URI.encode_www_form_component(value.to_s)
    end

    def blank?(value)
      value.nil? || value.to_s.empty?
    end
  end
end
