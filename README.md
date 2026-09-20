# RubyCoincheckClient

[日本語](#日本語) | [English](#english)

## 日本語

Coincheckの[取引所API](https://coincheck.com/ja/documents/exchange/api)を利用するためのRubyクライアントです。

Public APIとPrivate API、認証署名、単調増加するnonce、タイムアウト設定、構造化された例外に対応しています。レスポンスはJSONをパースした`Hash`または`Array`として返します。

### 動作要件

- Ruby 3.1以上

### インストール

アプリケーションの`Gemfile`に追加します。

```ruby
gem "ruby_coincheck_client"
```

その後、`bundle install`を実行してください。

### 基本的な使い方

Public APIは認証情報なしで利用できます。

```ruby
require "ruby_coincheck_client"

client = RubyCoincheckClient::Client.new
ticker = client.ticker(pair: "btc_jpy")
puts ticker.fetch("last")
```

Private APIにはAPIキーとシークレットキーが必要です。

```ruby
client = RubyCoincheckClient::Client.new(
  ENV.fetch("COINCHECK_API_KEY"),
  ENV.fetch("COINCHECK_API_SECRET")
)

balance = client.balance
orders = client.orders(pair: "btc_jpy")
```

従来の`CoincheckClient.new`も互換エイリアスとして利用できます。

### Public API

```ruby
client.ticker(pair: "btc_jpy")
client.trades(pair: "btc_jpy", limit: 20, order: "desc")
client.order_book(pair: "btc_jpy")
client.order_rate(order_type: "buy", amount: "0.01", pair: "btc_jpy")
client.rate(pair: "btc_jpy")
client.exchange_status
client.exchange_status(pair: "btc_jpy")
```

### 注文

```ruby
# 指値注文
client.create_order(
  order_type: "buy",
  pair: "btc_jpy",
  rate: "40000",
  amount: "0.01",
  time_in_force: "post_only"
)

# 成行注文
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

### アカウントと暗号資産の送受金

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

現在の送金APIでは、登録済みの`remittee_list_id`と`purpose_type`が必要です。暗号資産アドレスを直接指定する旧方式には対応していません。

### 日本円出金

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

### エラー処理と設定

HTTPエラーでは`RubyCoincheckClient::HTTPError`が発生します。例外から`status`、`headers`、パース済みの`body`を参照できます。JSONレスポンスの`"success"`が`false`の場合は`RubyCoincheckClient::APIError`、不正なJSONの場合は`RubyCoincheckClient::ResponseError`が発生します。

```ruby
begin
  client.balance
rescue RubyCoincheckClient::HTTPError => error
  warn "HTTP #{error.status}: #{error.body.inspect}"
end
```

タイムアウトとAPIのベースURLはクライアントごとに設定できます。

```ruby
client = RubyCoincheckClient::Client.new(
  api_key,
  api_secret,
  open_timeout: 5,
  read_timeout: 15,
  base_url: "https://coincheck.com/"
)
```

TLS証明書はデフォルトで検証されます。`verify_ssl: false`は管理されたローカルテスト環境専用です。本番APIに対して使用しないでください。

### 互換メソッド

`read_ticker`、`read_all_trades`、`read_order_books`、`read_balance`、`read_accounts`、`read_orders`、`read_transactions`など、従来の`read_*`メソッドは互換エイリアスとして残しています。新しいコードでは上記の短いメソッド名を使用してください。

すべてのメソッドはパース済みJSONを返します。古いREADMEに記載されていた戻り値への`.body`呼び出しは不要です。

### 開発

```console
bin/setup
bundle exec rake
```

対話的に動作を確認する場合は`bin/console`を使用してください。

---

## English

A Ruby client for the [Coincheck Exchange API](https://coincheck.com/ja/documents/exchange/api).

It supports the documented public and private APIs, authenticated request signing, monotonic nonces, configurable timeouts, and structured errors. Responses are returned as parsed JSON (`Hash` or `Array`).

### Requirements

- Ruby 3.1 or later

### Installation

Add the gem to your application's `Gemfile`:

```ruby
gem "ruby_coincheck_client"
```

Then run `bundle install`.

### Basic usage

Public endpoints do not require credentials:

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

### Public API

```ruby
client.ticker(pair: "btc_jpy")
client.trades(pair: "btc_jpy", limit: 20, order: "desc")
client.order_book(pair: "btc_jpy")
client.order_rate(order_type: "buy", amount: "0.01", pair: "btc_jpy")
client.rate(pair: "btc_jpy")
client.exchange_status
client.exchange_status(pair: "btc_jpy")
```

### Orders

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

### Account and crypto transfers

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

The current send-money API requires a registered `remittee_list_id` and a `purpose_type`. The legacy flow that accepted a raw crypto address is no longer supported.

### JPY withdrawals

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

### Errors and configuration

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

TLS certificates are verified by default. `verify_ssl: false` is intended only for controlled local testing and must not be used against the production API.

### Compatibility methods

The original `read_*` methods remain available as aliases, including `read_ticker`, `read_all_trades`, `read_order_books`, `read_balance`, `read_accounts`, `read_orders`, and `read_transactions`. New code should use the shorter method names shown above.

All methods return parsed JSON. The `.body` calls shown in older README versions are not required.

### Development

```console
bin/setup
bundle exec rake
```

Use `bin/console` for an interactive session.
