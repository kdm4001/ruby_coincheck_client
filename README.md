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

### 自分用のローカル GUI

このリポジトリには、日本語のブラウザ GUI を同梱しています。

```console
bundle install
bundle exec ruby bin/gui
```

起動時にターミナルで **GUI 専用パスワード（12 文字以上）** を 2 回入力します。入力は表示されません。Coincheck のログインパスワードや API キーとは別のものを設定してください。

ブラウザで **http://127.0.0.1:9292** を開き、そのパスワードでログインします。`127.0.0.1` のみに接続を受け付けます。ポートを変更する場合は `PORT=9393 bundle exec ruby bin/gui` としてください。

GUI パスワードはソルト付き PBKDF2-HMAC-SHA256（600,000 回）のハッシュとしてサーバーのメモリ内に保持し、ファイルには保存しません。再起動時には改めて設定します。非対話起動では環境変数 `COINCHECK_GUI_PASSWORD` も利用できますが、コマンド引数やシェル履歴にパスワードを直接書かないでください。パスワード未設定での起動はできません。

ログイン状態は HttpOnly / SameSite=Strict の Cookie で管理し、サーバー側で 8 時間の有効期限を設けています。未ログインでは `/api/session` を含むすべての API と WebSocket を拒否します。操作にはログイン Cookie と別の操作用トークンの両方が必要です。ログアウト時には当該セッションと WebSocket を無効化します。同じブラウザのほかのタブもログアウトし、別ブラウザのログインは維持されます。ログインに 60 秒以内で 5 回失敗すると、一時的に追加の試行を制限します。

API キーはログアウトだけでは削除しません。サーバーから取り除く場合は「API キー設定 → 登録を解除」を使用するか、サーバーを停止してください。API キーの使用中の平文保持や、PC の管理者権限・ブラウザセッションを奪われた場合まで防ぐものではありません。ローカルの HTTP 専用設計のため、LAN 公開・リバースプロキシ・外部公開には対応していません。

- 相場、約定価格チャート、板、最近の約定を表示
- Coincheck を想起させる白・グリーン基調のレスポンシブ UI、ライト / ダークモード切替、狭い画面向けハンバーガーメニュー
- BTC / JPY、ETH / JPY、XRP / JPY、SOL / JPY を選択式で切り替え（相場・板・注文・WebSocket を連動）
- 残高、未約定注文、自分の約定履歴（追加読み込みに対応）を表示
- ページ上部に総資産と通貨ごとの日本円評価額を表示。全保有通貨が対象で、注文中・貸出・つみたてを加算し、借入を控除します。Coincheck の基準レートによる概算で、手数料や売却時の価格差は含みません。
- 指値・成行の売買、逆指値、Post only、注文キャンセル
- 公開 WebSocket で約定・板の差分を受信
- Private WebSocket で注文・約定イベントを受信し、残高・注文・履歴を再取得
- 切断後の再接続・再購読、REST による定期更新

残高や注文を使う場合は、画面右上の **API キー設定** からキーとシークレットを入力して「接続を確認して登録」を押してください。残高参照で認証を確認した後、画面が更新されて利用可能になります。入力欄は送信時・閉じるときに消去し、登録済みのキーを再表示することはありません。

画面から登録したキーはサーバーのメモリ内のみで保持します。ファイルやブラウザの保存領域には書き込まず、サーバー再起動時に消去されます。「登録を解除」で現在のサーバーから削除することもできます。キーの変更・解除時は既存の WebSocket とほかのタブのセッションを更新します。

起動時に設定する場合は、従来どおり環境変数 `COINCHECK_API_KEY` と `COINCHECK_API_SECRET` も使えます。macOS 標準の zsh で入力を隠す例:

```zsh
read -rs 'COINCHECK_API_KEY?API key: '; echo
read -rs 'COINCHECK_API_SECRET?API secret: '; echo
export COINCHECK_API_KEY COINCHECK_API_SECRET
bundle exec ruby bin/gui
```

`.env` は自動では読み込みません。環境変数で設定したキーは、GUI で登録解除しても環境変数自体には変更を加えないため、次回起動時に再び使われます。キーをサーバーからブラウザへ返すことはありません。Coincheck 側で、残高参照・注文・取引履歴など利用する REST API と WebSocket の `order-events`・`execution-events` に権限を設定してください。GUI で送金・出金は扱いません。

注文とキャンセルは確認画面で確定すると**実際に送信されます**。同じ送信 ID の重複実行をサーバー内で防止し、通信失敗時に自動再送しません。結果が不明な場合は注文・約定履歴を確認してください。この重複防止情報は再起動時に消去されます。

板の配信には連続したシーケンス番号がないため、REST の全体取得に差分を重ねた参考値です。30 秒ごとに再取得し、再接続時にも復元しますが、厳密な同期や約定価格を保証するものではありません。チャートは直近の約定データを表示し、ローソク足や長期履歴ではありません。

資産評価も 30 秒ごと、および注文・約定イベント時に更新します。基準レートのキャッシュは最大 20 秒です。評価できない通貨がある場合はその通貨を「未評価」とし、総資産は「—」、取得できた分の評価額を別表示します。残高取得に失敗した場合は前回の値であることを表示します。

GUI はリポジトリから起動する開発用ツールで、公開サーバーへの配置には対応していません。複数タブではそれぞれ WebSocket 接続を作成します。同じ API キーを使う別プロセスとの nonce の共有には対応していないため、この GUI 専用のキーを使ってください。

起動済み GUI の公開 API と WebSocket を、発注せずに確認できます。実行時に GUI パスワードを非表示で入力します。検証用の GUI セッションは終了時にログアウトします。

```console
bundle exec ruby bin/check_gui
bundle exec ruby bin/check_gui eth_jpy
bundle exec ruby bin/check_gui xrp_jpy
bundle exec ruby bin/check_gui sol_jpy
```

### Ruby から WebSocket を利用する

[Coincheck 公式 WebSocket 仕様](https://coincheck.com/ja/documents/exchange/api#websocket-api)に対応しています。コールバックには JSON をパースした配列または Hash が渡ります。

```ruby
require "ruby_coincheck_client"
require "ruby_coincheck_client/websocket"

EventMachine.run do
  stream = RubyCoincheckClient::WebSocket.new(
    pair: "btc_jpy",
    on_message: ->(message) { puts message.inspect },
    on_status: ->(status) { warn status.inspect }
  ).start

  # 終了時: stream.stop; EventMachine.stop
end
```

Private WebSocket は `private_stream: true, client: client` を指定します。`client` は認証情報を持つ `RubyCoincheckClient::Client` です。REST と同じインスタンスを使用すると nonce の採番を共有できます。別スレッドで同じキーの REST と WebSocket 認証を併用する場合は、GUI 実装と同様に処理を直列化してください。署名に使用する URI は仕様に従い `wss://stream.coincheck.com/private` に固定しています。

`start` / `stop` と受信コールバックは EventMachine のイベントループ上で実行します。コールバックでは長時間の同期処理を避けてください。ネットワーク切断時は最大 30 秒まで待ち時間を増やして再接続します。認証・購読が拒否された場合は停止してエラー状態を通知します。

テスト:

```console
bundle exec rake
node --test spec/gui/market_test.mjs
```

Node.js は GUI の起動には不要で、JavaScript テストを実行するときのみ使用します。

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
