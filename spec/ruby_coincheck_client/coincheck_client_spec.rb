# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyCoincheckClient::Client do
  subject(:client) do
    described_class.new(
      "api-key",
      "secret-key",
      nonce_generator: -> { 1_700_000_000_000 }
    )
  end

  def stub_json(method, url, response_body: { success: true }, status: 200)
    stub_request(method, url).to_return(
      status: status,
      body: JSON.generate(response_body),
      headers: { "Content-Type" => "application/json" }
    )
  end

  describe "public endpoints" do
    it "returns parsed ticker JSON" do
      stub_json(
        :get,
        "https://coincheck.com/api/ticker?pair=eth_jpy",
        response_body: { last: 123_456, volume: "1.25" }
      )

      expect(client.ticker(pair: "eth_jpy")).to eq("last" => 123_456, "volume" => "1.25")
    end

    it "supports pagination when reading trades" do
      request = stub_json(
        :get,
        "https://coincheck.com/api/trades?limit=10&order=asc&pair=btc_jpy"
      )

      client.trades(limit: 10, order: "asc")

      expect(request).to have_been_requested
    end

    it "requests the order book for a pair" do
      request = stub_json(:get, "https://coincheck.com/api/order_books?pair=btc_jpy")

      client.order_book

      expect(request).to have_been_requested
    end

    it "requests an estimated order rate without nil query parameters" do
      request = stub_json(
        :get,
        "https://coincheck.com/api/exchange/orders/rate?amount=0.1&order_type=buy&pair=btc_jpy"
      )

      client.order_rate(order_type: :buy, amount: "0.1")

      expect(request).to have_been_requested
    end

    it "requires a price or amount for an estimated order rate" do
      expect { client.order_rate(order_type: :buy) }
        .to raise_error(ArgumentError, "price or amount is required")
    end

    it "requests the reference rate" do
      request = stub_json(:get, "https://coincheck.com/api/rate/btc_jpy")

      client.rate

      expect(request).to have_been_requested
    end

    it "omits pair when requesting every exchange status" do
      request = stub_json(:get, "https://coincheck.com/api/exchange_status")

      client.exchange_status

      expect(request).to have_been_requested
    end
  end

  describe "authentication" do
    it "signs the nonce and complete request URL" do
      nonce = "1700000000000"
      url = "https://coincheck.com/api/accounts/balance"
      signature = OpenSSL::HMAC.hexdigest("SHA256", "secret-key", "#{nonce}#{url}")
      stub_json(:get, url)

      client.balance

      expect(WebMock).to have_requested(:get, url).with(
        headers: {
          "Access-Key" => "api-key",
          "Access-Nonce" => nonce,
          "Access-Signature" => signature
        }
      )
    end

    it "keeps nonces increasing when the clock does not move" do
      stub_json(:get, "https://coincheck.com/api/accounts")

      2.times { client.account }

      expect(WebMock).to have_requested(:get, "https://coincheck.com/api/accounts").with(
        headers: { "Access-Nonce" => "1700000000000" }
      ).once
      expect(WebMock).to have_requested(:get, "https://coincheck.com/api/accounts").with(
        headers: { "Access-Nonce" => "1700000000001" }
      ).once
    end

    it "rejects private requests without credentials" do
      anonymous_client = described_class.new

      expect { anonymous_client.balance }
        .to raise_error(RubyCoincheckClient::ConfigurationError, /key and secret/)
    end
  end

  describe "orders" do
    it "creates a limit order with exactly the documented fields" do
      body = JSON.generate(
        pair: "btc_jpy",
        order_type: "buy",
        rate: "40000",
        amount: "0.01",
        time_in_force: "post_only"
      )
      nonce = "1700000000000"
      signature = OpenSSL::HMAC.hexdigest(
        "SHA256",
        "secret-key",
        "#{nonce}https://coincheck.com/api/exchange/orders#{body}"
      )
      stub_json(:post, "https://coincheck.com/api/exchange/orders")

      client.create_order(
        order_type: :buy,
        rate: "40000",
        amount: "0.01",
        time_in_force: "post_only"
      )

      expect(WebMock).to have_requested(:post, "https://coincheck.com/api/exchange/orders").with(
        body: body,
        headers: { "Access-Signature" => signature, "Content-Type" => "application/json" }
      )
    end

    it "validates fields required by each order type" do
      expect { client.create_order(order_type: :sell, amount: "0.01") }
        .to raise_error(ArgumentError, /rate and amount/)
      expect { client.create_order(order_type: :market_buy) }
        .to raise_error(ArgumentError, /market_buy_amount/)
      expect { client.create_order(order_type: :market_sell) }
        .to raise_error(ArgumentError, /amount/)
    end

    it "reads order details" do
      request = stub_json(:get, "https://coincheck.com/api/exchange/orders/123")

      client.order(id: 123)

      expect(request).to have_been_requested
    end

    it "filters open orders by pair without mutating the API shape" do
      stub_json(
        :get,
        "https://coincheck.com/api/exchange/orders/opens",
        response_body: {
          success: true,
          orders: [
            { id: 1, pair: "btc_jpy" },
            { id: 2, pair: "eth_jpy" }
          ]
        }
      )

      expect(client.orders(pair: "eth_jpy").fetch("orders").map { |order| order["id"] }).to eq([2])
    end

    it "cancels an order and reads its cancellation status" do
      delete_request = stub_json(:delete, "https://coincheck.com/api/exchange/orders/123")
      status_request = stub_json(
        :get,
        "https://coincheck.com/api/exchange/orders/cancel_status?id=123"
      )

      client.cancel_order(id: 123)
      client.cancel_status(id: 123)

      expect(delete_request).to have_been_requested
      expect(status_request).to have_been_requested
    end

    it "returns every cancellation response from cancel_all_orders" do
      stub_json(
        :get,
        "https://coincheck.com/api/exchange/orders/opens",
        response_body: { success: true, orders: [{ id: 1 }, { id: 2 }] }
      )
      stub_json(
        :delete,
        %r{https://coincheck\.com/api/exchange/orders/[12]},
        response_body: { success: true }
      )

      expect(client.cancel_all_orders).to eq(
        [{ "success" => true }, { "success" => true }]
      )
    end
  end

  describe "account and transfer endpoints" do
    it "returns all dynamic balance fields unchanged" do
      response = {
        success: true,
        btc: "1.0",
        btc_reserved: "0.1",
        btc_lent: "0.2",
        btc_tsumitate: "0.3"
      }
      stub_json(
        :get,
        "https://coincheck.com/api/accounts/balance",
        response_body: response
      )

      expect(client.balance).to eq(JSON.parse(JSON.generate(response)))
    end

    it "requests paginated transactions" do
      request = stub_json(
        :get,
        "https://coincheck.com/api/exchange/orders/transactions_pagination?limit=25&starting_after=10"
      )

      client.transactions_pagination(limit: 25, starting_after: 10)

      expect(request).to have_been_requested
    end

    it "sends crypto using a remittee-list entry and purpose" do
      stub_json(:post, "https://coincheck.com/api/send_money")

      client.send_money(
        remittee_list_id: 123,
        amount: "0.01",
        purpose_type: "keep_own_private_wallet"
      )

      expect(WebMock).to have_requested(:post, "https://coincheck.com/api/send_money").with(
        body: JSON.generate(
          remittee_list_id: 123,
          amount: "0.01",
          purpose_type: "keep_own_private_wallet"
        )
      )
    end

    it "reads send and deposit histories by currency" do
      sends = stub_json(:get, "https://coincheck.com/api/send_money?currency=ETH")
      deposits = stub_json(:get, "https://coincheck.com/api/deposit_money?currency=ETH")

      client.send_money_history(currency: "ETH")
      client.deposits(currency: "ETH")

      expect(sends).to have_been_requested
      expect(deposits).to have_been_requested
    end
  end

  describe "JPY withdrawal endpoints" do
    it "creates and deletes bank accounts" do
      stub_json(:post, "https://coincheck.com/api/bank_accounts")
      delete_request = stub_json(:delete, "https://coincheck.com/api/bank_accounts/42")

      client.create_bank_account(
        bank_name: "Bank",
        branch_name: "Branch",
        bank_account_type: "futsu",
        number: "****456",
        name: "TARO"
      )
      client.delete_bank_account(id: 42)

      expect(WebMock).to have_requested(:post, "https://coincheck.com/api/bank_accounts").with(
        body: JSON.generate(
          bank_name: "Bank",
          branch_name: "Branch",
          bank_account_type: "futsu",
          number: "****456",
          name: "TARO"
        )
      )
      expect(delete_request).to have_been_requested
    end

    it "lists, creates, and cancels withdrawals" do
      list_request = stub_json(
        :get,
        "https://coincheck.com/api/withdraws?limit=10&order=desc"
      )
      stub_json(:post, "https://coincheck.com/api/withdraws")
      cancel_request = stub_json(:delete, "https://coincheck.com/api/withdraws/99")

      client.withdraws(limit: 10, order: "desc")
      client.create_withdraw(bank_account_id: 42, amount: "10000")
      client.cancel_withdraw(id: 99)

      expect(list_request).to have_been_requested
      expect(WebMock).to have_requested(:post, "https://coincheck.com/api/withdraws").with(
        body: JSON.generate(bank_account_id: 42, amount: "10000", currency: "JPY")
      )
      expect(cancel_request).to have_been_requested
    end
  end

  describe "error handling" do
    it "raises an HTTPError with structured response details" do
      stub_json(
        :get,
        "https://coincheck.com/api/ticker?pair=btc_jpy",
        status: 429,
        response_body: { success: false, error: "too_many_requests" }
      )

      expect { client.ticker }.to raise_error(RubyCoincheckClient::HTTPError) { |error|
        expect(error.status).to eq(429)
        expect(error.body).to include("error" => "too_many_requests")
      }
    end

    it "raises an APIError for a successful HTTP response with success false" do
      stub_json(
        :get,
        "https://coincheck.com/api/ticker?pair=btc_jpy",
        response_body: { success: false, error: "invalid_pair" }
      )

      expect { client.ticker }
        .to raise_error(RubyCoincheckClient::APIError, /invalid_pair/)
    end

    it "raises a ResponseError for invalid JSON" do
      stub_request(:get, "https://coincheck.com/api/ticker?pair=btc_jpy")
        .to_return(status: 200, body: "not-json")

      expect { client.ticker }
        .to raise_error(RubyCoincheckClient::ResponseError, /invalid JSON/)
    end

    it "preserves the HTTP status when an error body is not JSON" do
      stub_request(:get, "https://coincheck.com/api/ticker?pair=btc_jpy")
        .to_return(status: 502, body: "bad gateway")

      expect { client.ticker }.to raise_error(RubyCoincheckClient::HTTPError) { |error|
        expect(error.status).to eq(502)
        expect(error.body).to eq("bad gateway")
      }
    end
  end

  describe "configuration" do
    it "keeps base URLs isolated between instances" do
      first = described_class.new(base_url: "http://first.example.test/")
      second = described_class.new(base_url: "http://second.example.test/")
      first_request = stub_json(:get, "http://first.example.test/api/rate/btc_jpy")
      second_request = stub_json(:get, "http://second.example.test/api/rate/btc_jpy")

      first.rate
      second.rate

      expect(first_request).to have_been_requested
      expect(second_request).to have_been_requested
    end

    it "supports the original positional options hash" do
      legacy_client = described_class.new(nil, nil, { base_url: "http://legacy.example.test/" })
      request = stub_json(:get, "http://legacy.example.test/api/rate/btc_jpy")

      legacy_client.rate

      expect(request).to have_been_requested
    end

    it "rejects invalid base URLs" do
      expect { described_class.new(base_url: "coincheck.com") }
        .to raise_error(RubyCoincheckClient::ConfigurationError, /absolute/)
    end
  end

  describe "compatibility" do
    it "retains the original top-level class and reader names" do
      expect(CoincheckClient).to equal(described_class)
      expect(client).to respond_to(:read_ticker, :read_trades, :read_balance, :create_orders)
    end
  end
end
