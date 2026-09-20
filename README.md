# RubyCoincheckClient

A small Ruby client for the [Coincheck Exchange API](https://coincheck.com/ja/documents/exchange/api).

It supports the documented REST public and private endpoints, authenticated request signing, monotonic nonces, configurable timeouts, and structured errors. Responses are returned as parsed JSON (`Hash` or `Array`).

## Installation

Add the gem to your application:

```ruby
gem "ruby_coincheck_client"
```

Then run `bundle install`.

## Usage

```ruby
require "ruby_coincheck_client"

client = RubyCoincheckClient::Client.new
ticker = client.ticker(pair: "btc_jpy")
puts ticker.fetch("last")
```

Private endpoints require an API key and secret:

```ruby
client = RubyCoincheckClient::Client.new(
  ENV.fetch("COINCHECK_API_KEY"),
  ENV.fetch("COINCHECK_API_SECRET")
)

balance = client.balance
orders = client.orders(pair: "btc_jpy")
```

`CoincheckClient.new` remains available as a compatibility alias.

## Public API

```ruby
client.ticker(pair: "btc_jpy")
client.trades(pair: "btc_jpy", limit: 20, order: "desc")
client.order_book(pair: "btc_jpy")
client.order_rate(order_type: "buy", amount: "0.01", pair: "btc_jpy")
client.rate(pair: "btc_jpy")
client.exchange_status
client.exchange_status(pair: "btc_jpy")
```

## Orders

```ruby
# Limit order
client.create_order(
  order_type: "buy",
  pair: "btc_jpy",
  rate: "40000",
  amount: "0.01",
  time_in_force: "post_only"
)

# Market orders
client.create_order(order_type: "market_buy", market_buy_amount: "10000")
client.create_order(order_type: "market_sell", amount: "0.01")

client.order(id: 12345)
client.orders
client.cancel_order(id: 12345)
client.cancel_status(id: 12345)
client.cancel_all_orders(pair: "btc_jpy")
client.transactions
client.transactions_pagination(limit: 25, order: "desc")
```

## Account and transfers

```ruby
client.balance
client.account

client.send_money(
  remittee_list_id: 12345,
  amount: "0.001",
  purpose_type: "keep_own_private_wallet"
)
client.send_money_history(currency: "BTC")
client.deposits(currency: "BTC")
```

Coincheck's current send-money API requires a registered `remittee_list_id` and a `purpose_type`; it no longer accepts a raw address.

## JPY withdrawals

```ruby
client.bank_accounts
client.create_bank_account(
  bank_name: "Bank",
  branch_name: "Branch",
  bank_account_type: "futsu",
  number: "****456",
  name: "TARO YAMADA"
)
client.delete_bank_account(id: 42)

client.withdraws(limit: 25, order: "desc")
client.create_withdraw(bank_account_id: 42, amount: "10000")
client.cancel_withdraw(id: 99)
```

## Errors and configuration

HTTP failures raise `RubyCoincheckClient::HTTPError`. The exception exposes `status`, `headers`, and the parsed `body`. A JSON response containing `"success": false` raises `RubyCoincheckClient::APIError`; invalid JSON raises `RubyCoincheckClient::ResponseError`.

```ruby
begin
  client.balance
rescue RubyCoincheckClient::HTTPError => error
  warn "HTTP #{error.status}: #{error.body.inspect}"
end
```

Timeouts and the API base URL can be configured per client:

```ruby
client = RubyCoincheckClient::Client.new(
  api_key,
  api_secret,
  open_timeout: 5,
  read_timeout: 15,
  base_url: "https://coincheck.com/"
)
```

TLS certificates are verified by default. `verify_ssl: false` exists only for controlled local testing and should not be used against the production API.

## Compatibility names

The original `read_*` names are retained as aliases, including `read_ticker`, `read_all_trades`, `read_order_books`, `read_balance`, `read_accounts`, `read_orders`, and `read_transactions`. New code should use the shorter names shown above.

All methods return parsed JSON. Older README versions incorrectly showed calls to `.body` on these return values.

## Development

```console
bin/setup
bundle exec rake
```

Use `bin/console` for an interactive session.
