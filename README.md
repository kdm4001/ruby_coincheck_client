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

ログイン状態は HttpOnly / SameSite=Strict の Cookie で管理し、サーバー側で既定 8 時間の有効期限を設けています（起動時に変更可能）。未ログインでは `/api/session` を含むすべての API と WebSocket を拒否します。操作にはログイン Cookie と別の操作用トークンの両方が必要です。ログアウト時には当該セッションと WebSocket を無効化します。同じブラウザのほかのタブもログアウトし、別ブラウザのログインは維持されます。ログインに 60 秒以内で 5 回失敗すると、一時的に追加の試行を制限します。

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

### ローカルの擬似IOCエンドポイント

`POST /api/orders/immediate_or_cancel` は指値注文を1回送信し、注文IDを受け取った直後にキャンセルを1回要求して、注文詳細から結果を確認します。対象は `buy` / `sell` です。GUIでは「取引デスクへ」から指値買い・指値売りを選び、有効期間を「擬似IOC」にすると利用できます。

これは取引所ネイティブのIOCではありません。注文からキャンセルまでの間も約定し得ます。通信障害・キャンセル拒否・サーバー停止時には注文が残る可能性があり、即時取消を保証しません。[Coincheck公式の注文・キャンセル・注文詳細API](https://coincheck.com/ja/documents/exchange/api)を組み合わせています。

通常のGUI APIと同じく、GUIログインのCookieと `/api/session` で取得する `token` を `X-Local-Token` ヘッダーに指定し、`Content-Type: application/json` を付けます。`Origin` を送る場合はローカルGUIのURLと一致させてください。CoincheckのAPIキーには新規注文・キャンセル・注文詳細の権限が必要です。

リクエスト例（送信すると実際に発注します）:

```json
{
  "request_id": "ioc-example-00000001",
  "pair": "btc_jpy",
  "order_type": "buy",
  "rate": "10000000",
  "amount": "0.001"
}
```

`request_id` は英数字・アンダースコア・ハイフンの16〜80文字で、注文ごとに一意にしてください。数値は正の十進文字列で指定します。成行注文、`stop_loss_rate`、`time_in_force`、その他の余分なフィールドは拒否します。

部分約定後にキャンセルできた場合のレスポンス例:

```json
{
  "request_id": "ioc-example-00000001",
  "mode": "emulated_immediate_or_cancel",
  "pair": "btc_jpy",
  "order_type": "buy",
  "requested_amount": "0.001",
  "rate": "10000000",
  "order_id": "42",
  "status": "canceled",
  "cancel_request": "accepted",
  "executed_amount": "0.0004",
  "remaining_amount": "0.0",
  "canceled_amount": "0.0006",
  "expired_amount": "0.0",
  "terminal": true,
  "uncertain": false,
  "requires_attention": false,
  "exchange_status": "PARTIALLY_FILLED_CANCELED",
  "checked_at": "2026-10-03T00:00:00Z"
}
```

| `status` | 意味 | HTTP |
| --- | --- | --- |
| `filled` | 全量約定済み | 200 |
| `canceled` | キャンセル済み。一部約定している場合もあります | 200 |
| `expired` | 失効済み。一部約定している場合もあります | 200 |
| `rejected` | 新規注文が明確に拒否された | 422 |
| `open` | 確認時点で未約定分が残っている | 202 |
| `unknown` | 注文の受理または最終状態を確認できない | 202 |

`cancel_request` は取消要求への応答（`accepted` / `rejected` / `unknown` / `not_sent`）であり、注文の最終状態ではありません。数量を確認できない場合はゼロではなく `null` を返します。`terminal: false` / `requires_attention: true` の場合は、注文が残っていないか確認が必要です。

`GET /api/orders/immediate_or_cancel/{request_id}` で結果を照会できます。未確定で注文IDが判明している場合だけ、注文詳細を再取得します。GETは発注・キャンセルを行いません。注文詳細の取得はこのサーバー内で約1秒以上の間隔を空けます。他のクライアントとのレート制限調整は行いません。

POSTは処理完了まで待つ同期APIです。クライアントがタイムアウトしたりブラウザを閉じたりしても、サーバープロセスが動作している限り処理を続けます。同じ `request_id`・同じ本文で再POSTすると保存済み結果を返し、新しい注文は送信しません。異なる本文・別の注文エンドポイントで同じIDを使用すると409を返します。最新状態を確認したい場合はGETを使ってください。

HTTP 202は自動再試行を予約した意味ではありません。自動で発注・取消を繰り返すことはありません。新規注文の応答が失われて注文IDを特定できない場合、別の注文を誤って取り消さないよう推測でキャンセルせず、`unknown` を返します。Coincheckの注文・約定履歴で確認してください。

重複防止と結果の記録はサーバーのメモリ内のみです。再起動後は同じIDでも新規発注になり得るため、未確定のリクエストを再起動後に再送しないでください。APIキーの変更・解除後は以前の接続の結果を照会できません。同じプロセス内では以前使ったIDの再利用も拒否します。

### ローカルの期限付き注文（GTD）

`POST /api/orders/good_til_date` で指値注文と取消期限を登録します。認証は上記の擬似IOCと同じです。対応フィールドは `request_id`、`pair`、`order_type`（`buy` / `sell`）、`rate`、`amount`、`expires_at` のみです。

```json
{
  "request_id": "gtd-example-00000001",
  "pair": "btc_jpy",
  "order_type": "buy",
  "rate": "10000000",
  "amount": "0.001",
  "expires_at": "2026-10-04T18:00:00+09:00"
}
```

`expires_at` はタイムゾーン付きISO 8601で、送信時点より未来かつ7日以内を指定します。上の日時は例なので、実行時に置き換えてください。POSTすると実際に発注します。受付時はHTTP 202、`mode: emulated_good_til_date` と期限を返します。結果フィールドは擬似IOCと共通です。

サーバーは約1秒間隔で期限を確認し、期限切れの注文の未約定分を取り消します。部分約定した分は取り消せません。取消後に注文詳細を確認し、未完了・確認不能なら30秒以上空けて取消を再試行します。新規発注は再試行しません。複数注文は順に処理するため、通信処理やAPI制限などで期限から遅れる可能性があります。

`GET /api/orders/good_til_date/{request_id}` は注文詳細を読み取って結果を更新します。照会自体では発注・取消を行いません。期限前の正常な未約定注文は `requires_attention: false`、期限後に未完了または確認不能なら `true` です。同じID・同じ本文のPOSTは保存結果を返し、二重発注しません。

ブラウザを閉じてもログアウトしても監視は続きますが、**サーバーの停止・PCのスリープ中は取消できず、再起動後の予約復元もありません**。停止前に未約定注文を取り消し、結果を確認してください。新規注文の応答が失われてIDが不明な場合も自動取消できません。取引所側に期限は設定されません。GTDの記録・重複防止はメモリ内のみです。

取消対象のアカウントを維持するため、注文IDが判明している未完了GTDがある間はAPIキーの変更・解除を409で拒否します。手動取消・全約定後はGTD結果をGETで照会して完了を確認すると解除できます。永続化は今回の対象外です。

GUIでは「取引デスクへ」から指値買い・指値売りを選び、有効期間を「GTD」にして取消期限を入力します。期限は端末の現地時刻で、確認画面にも表示します。成行注文では「通常」に戻り、IOC・GTDでは逆指値・Post onlyを併用できません。

処理結果は専用欄に表示し、未完了分を30秒ごとに照会します。「結果を照会」ボタンは再発注しません。通信切断時もリクエストIDを表示します。一覧は再読み込みで消えるので、未確定の場合はIDを控えてください。

### 自宅で常時表示する

初期表示はダッシュボードです。主要4通貨の価格・24時間高安値、総資産、資産推移をまとめて表示します。通貨カードを押すと詳細チャートの対象も切り替わります。「取引デスクへ」で注文・板・履歴を含む画面に戻れます。表示モードはこのブラウザに保存します。

- 相場一覧は30秒ごとに取得し、取得後の経過時間を表示します。取得失敗・90秒以上の遅延・オフラインを明示します。
- 「全画面」と「画面を点灯維持」は対応ブラウザで利用できます。点灯維持はページを表示している間の機能で、PCの蓋を閉じた状態やOSのスリープを解除するものではありません。
- 長時間表示では、ログイン期限を1〜168時間の整数で指定できます。これは注文を含むGUI全体のログイン期限です。既定は8時間、期限到達時には再ログインします。

```console
COINCHECK_GUI_SESSION_HOURS=168 bundle exec ruby bin/gui
```

起動後、`http://127.0.0.1:9292` を開きます。サーバーを動かすターミナルを開いたまま、PCがスリープしない設定で利用してください。

APIキー登録後、サーバーは約1分ごとに残高・基準レートを確認し、総資産評価額を約5分間隔で保存します。ブラウザを閉じたりログアウトしたりしても、サーバーが動作しAPIキーが登録されていれば記録します。APIキー解除・PCのスリープ・サーバー停止中は記録できません。起動前の履歴は取得しません。

総資産グラフは24時間・7日・30日を切り替えられます。未評価の通貨がある時点は保存せず、15分を超える記録の空白は線をつなぎません。表示する変化額には入出金・売買が含まれ、運用損益ではありません。

履歴はリポジトリ内の `data/portfolio/` に、時刻と総資産評価額だけをJSONで保存します。APIキーや残高明細は保存しません。ファイルは所有者だけが読み書きでき、Gitの追跡対象外です。同じAPIキーで再接続すると続きから表示し、異なるキーの履歴は分けます。新しい記録の保存時に、そのキーの30日より古い記録を削除します。キー解除後も保存ファイルは残ります。削除したい場合はサーバー停止後に対象の履歴ファイルを削除してください。同じ保存先を使うサーバーは1つだけ起動してください。

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
node --test spec/gui/market_test.mjs spec/gui/asset_history_test.mjs
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
