# frozen_string_literal: true

require "rack"
require "securerandom"
require "bigdecimal"
require_relative "auth"
require_relative "portfolio"
require_relative "portfolio_history"
require_relative "immediate_or_cancel"
require_relative "../lib/ruby_coincheck_client"
require_relative "../lib/ruby_coincheck_client/websocket"

module RubyCoincheckClient
  module GUI
    class App
      ASSETS = {
        "/" => ["index.html", "text/html; charset=utf-8"],
        "/login" => ["login.html", "text/html; charset=utf-8"],
        "/login.js" => ["login.js", "text/javascript; charset=utf-8"],
        "/app.js" => ["app.js", "text/javascript; charset=utf-8"],
        "/dashboard.js" => ["dashboard.js", "text/javascript; charset=utf-8"],
        "/asset-history.js" => ["asset-history.js", "text/javascript; charset=utf-8"],
        "/market.js" => ["market.js", "text/javascript; charset=utf-8"],
        "/style.css" => ["style.css", "text/css; charset=utf-8"]
      }.freeze
      SECURITY_HEADERS = {
        "cache-control" => "no-store",
        "x-content-type-options" => "nosniff",
        "referrer-policy" => "no-referrer",
        "content-security-policy" => "default-src 'self'; connect-src 'self'; style-src 'self'; script-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
      }.freeze

      def initialize(login_password:, port: 9292, client: nil, authenticated: nil, session_seconds: Auth::SESSION_SECONDS,
                     history_directory: nil, wall_clock: -> { Time.now },
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @auth = Auth.new(login_password, session_seconds: session_seconds, clock: clock)
        @portfolio = Portfolio.new
        key = ENV["COINCHECK_API_KEY"]
        secret = ENV["COINCHECK_API_SECRET"]
        @authenticated = authenticated.nil? ? [key, secret].all? { |value| value && !value.empty? } : authenticated
        @client = client || Client.new(key, secret, open_timeout: 5, read_timeout: 10)
        @history = PortfolioHistory.new(directory: history_directory)
        @history.select_account(@authenticated ? key : nil)
        @history_error = nil
        @monitor_mutex = Mutex.new
        @monitor_condition = ConditionVariable.new
        @hosts = ["127.0.0.1:#{port}", "localhost:#{port}"]
        @token = SecureRandom.hex(32)
        @api_mutex = Mutex.new
        @writes = {}
        @wall_clock = wall_clock
        @sockets = {} # Accessed only on the EventMachine reactor.
      end

      # Recording is server-owned so closing the browser or expiring its login
      # does not leave gaps while the local server and API credentials remain.
      def start_monitoring
        return if @monitor_thread&.alive?
        @monitoring = true
        @monitor_thread = Thread.new do
          loop do
            @api_mutex.synchronize do
              process_gtd
              begin
                now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
                if @authenticated && (!@last_portfolio_sample || now - @last_portfolio_sample >= 60)
                  @last_portfolio_sample = now
                  portfolio_snapshot
                end
              rescue StandardError
                @history_error = "資産の取得に失敗しました。次回の自動取得を待っています。"
              end
            end
            running = @monitor_mutex.synchronize do
              @monitor_condition.wait(@monitor_mutex, 1) if @monitoring
              @monitoring
            end
            break unless running
          end
        end
      end

      def stop_monitoring
        @monitor_mutex.synchronize do
          @monitoring = false
          @monitor_condition.broadcast
        end
        @monitor_thread&.join
      end

      def call(env)
        request = Rack::Request.new(env)
        return json(403, error: "ローカルからのみアクセスできます") unless @hosts.include?(env["HTTP_HOST"])
        origin = env["HTTP_ORIGIN"]
        return json(403, error: "アクセス元を確認できません") if origin && origin != "http://#{env['HTTP_HOST']}"
        login_id = request.cookies[Auth::COOKIE]

        if request.post? && request.path == "/api/login"
          return json(403, error: "アクセス元を確認できません") unless origin
          return login(request, login_id)
        end

        if request.get? && ASSETS.key?(request.path)
          filename, content_type = ASSETS.fetch(request.path)
          filename = "login.html" if request.path == "/" && !@auth.valid?(login_id)
          return [200, SECURITY_HEADERS.merge("content-type" => content_type), [File.read(File.join(__dir__, "public", filename))]]
        end
        return login_required unless @auth.valid?(login_id)
        if request.get? && request.path == "/api/session"
          return @api_mutex.synchronize { @auth.valid?(login_id) ? session_response : login_required }
        end
        if request.get? && request.path == "/stream"
          protocols = env.fetch("HTTP_SEC_WEBSOCKET_PROTOCOL", "").split(/,\s*/)
          stream_token = @token
          return json(403, error: "接続を認証できません") unless origin && protocols.include?(stream_token)
          return stream(env, pair(request), stream_token, login_id) if Faye::WebSocket.websocket?(env)
        end
        return json(403, error: "ページを再読み込みしてください") unless valid_token?(env["HTTP_X_LOCAL_TOKEN"])

        @api_mutex.synchronize do
          next login_required unless @auth.valid?(login_id)
          # Credentials can change while a request is waiting for this lock.
          next json(403, error: "API キー設定が変更されました。ページを再読み込みしてください") unless valid_token?(env["HTTP_X_LOCAL_TOKEN"])

          if request.post? && request.path == "/api/logout"
            read_json(request)
            @auth.logout(login_id)
            close_invalid_streams
            response = json(200, success: true)
            response[1]["set-cookie"] = Rack::Utils.set_cookie_header(Auth::COOKIE, value: "", path: "/", httponly: true, same_site: :strict, max_age: 0)
            next response
          end
          route(request)
        end
      rescue ArgumentError, JSON::ParserError, KeyError
        json(400, error: "入力内容を確認してください")
      rescue RubyCoincheckClient::Error => error
        json(502, error: error.message)
      rescue IOError, SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError
        json(502, error: "Coincheck への接続に失敗しました。しばらくしてから更新してください")
      rescue StandardError => error
        warn "GUI request failed: #{error.class}" # Never log bodies or credentials.
        json(500, error: "処理に失敗しました")
      end

      private

      def login(request, previous_id)
        body = read_json(request)
        status, id = @auth.login(body["password"], previous_id: previous_id)
        if status == :limited
          response = json(429, error: "ログイン試行が多すぎます。しばらく待ってから再試行してください。")
          response[1]["retry-after"] = Auth::RETRY_SECONDS.to_s
          return response
        end
        return json(401, error: "パスワードが正しくありません") unless status == :ok

        close_invalid_streams
        response = json(200, success: true)
        # HTTP is restricted to loopback. Never expose this server via a proxy
        # or LAN. HttpOnly prevents JavaScript from reading the session cookie.
        response[1]["set-cookie"] = Rack::Utils.set_cookie_header(Auth::COOKIE, value: id, path: "/", httponly: true, same_site: :strict)
        response
      end

      def login_required
        json(401, error: "GUI へのログインが必要です", code: "login_required")
      end

      def route(request)
        if request.post? && %w[/api/credentials /api/credentials/clear].include?(request.path) && pending_gtd?
          return json(409, error: "未完了のGTD注文があります。キャンセル後にGTD結果を照会して完了を確認してからAPIキーを変更してください。")
        end
        if request.post? && request.path == "/api/credentials"
          return register_credentials(request)
        end
        if request.post? && request.path == "/api/credentials/clear"
          read_json(request)
          replace_client(Client.new(open_timeout: 5, read_timeout: 10), authenticated: false)
          return session_response
        end
        if request.get?
          case request.path
          when "/api/ticker" then return json(200, @client.ticker(pair: pair(request)))
          when "/api/book" then return json(200, @client.order_book(pair: pair(request)))
          when "/api/trades" then return json(200, @client.trades(pair: pair(request), limit: 50, order: "desc"))
          end
        end
        return json(401, error: "画面右上の「API キー設定」から登録してください") unless @authenticated

        if request.get? && %r{\A/api/orders/immediate_or_cancel/[\w-]{16,80}\z}.match?(request.path)
          return ioc_result(request.path.split("/").last)
        end
        if request.get? && %r{\A/api/orders/good_til_date/[\w-]{16,80}\z}.match?(request.path)
          return gtd_result(request.path.split("/").last)
        end

        if request.get?
          case request.path
          when "/api/balance" then return json(200, @client.balance)
          when "/api/portfolio" then return json(200, portfolio_snapshot)
          when "/api/portfolio/history"
            days = Integer(request.params.fetch("days", "1"))
            raise ArgumentError unless [1, 7, 30].include?(days)
            begin
              return json(200, points: @history.points(days: days), error: @history_error)
            rescue StandardError
              return json(200, points: [], error: "保存した履歴を読み込めません。data/portfolio を確認してください。")
            end
          when "/api/orders" then return json(200, @client.orders(pair: pair(request)))
          when "/api/transactions"
            after = request.params["starting_after"]
            raise ArgumentError if after && !/\A\d+\z/.match?(after)
            return json(200, @client.transactions_pagination(limit: 25, order: "desc", starting_after: after))
          end
        end

        if request.post? && (["/api/orders", "/api/orders/immediate_or_cancel", "/api/orders/good_til_date"].include?(request.path) || %r{\A/api/orders/\d+/cancel\z}.match?(request.path))
          return mutate(request)
        end
        json(404, error: "見つかりません")
      end

      def read_json(request)
        raise ArgumentError unless request.media_type == "application/json"

        raw = request.body.read(8193)
        raise ArgumentError if raw.bytesize > 8192
        body = JSON.parse(raw)
        raise ArgumentError unless body.is_a?(Hash)
        body
      end

      def register_credentials(request)
        body = read_json(request)
        values = %w[api_key api_secret].map do |name|
          value = body.fetch(name)
          raise ArgumentError unless value.is_a?(String) && /\A[!-~]{1,512}\z/.match?(value)
          value
        end
        candidate = Client.new(*values, open_timeout: 5, read_timeout: 10)
        # A read-only check before replacing working credentials. Never return
        # upstream error text here: it may echo credentials or request details.
        begin
          candidate.balance
        rescue StandardError
          return json(422, error: "接続確認に失敗しました。API キー・シークレット・残高参照権限・IP 制限と通信状態を確認してください。現在の設定は変更していません。")
        end
        replace_client(candidate, authenticated: true, account_key: values.first)
        session_response
      end

      def replace_client(client, authenticated:, account_key: nil)
        @client = client
        @authenticated = authenticated
        @history.select_account(authenticated ? account_key : nil)
        @history_error = nil
        @token = SecureRandom.hex(32)
        close_invalid_streams
      end

      def close_invalid_streams
        # Stop streams from the previous account, including other browser tabs.
        return unless EventMachine.reactor_running?

        EventMachine.schedule do
          @sockets.dup.each do |socket, state|
            next if stream_active?(state[:token], state[:login_id])
            event = @auth.valid?(state[:login_id]) ? "session_changed" : "login_required"
            socket.send(JSON.generate(type: event))
            socket.close
          end
        end
      end

      def session_response
        json(200, token: @token, authenticated: @authenticated)
      end

      def portfolio_snapshot
        data = @portfolio.call(@client.balance)
        begin
          @history.record(data)
          @history_error = data[:missing_rates].empty? ? nil : "未評価の通貨があるため、この時点の総資産は記録していません。"
        rescue StandardError
          @history_error = "資産履歴を保存できません。data/portfolio の空き容量・書き込み権限を確認してください。"
        end
        data
      end

      def mutate(request)
        body = read_json(request)

        id = body.fetch("request_id")
        raise ArgumentError unless id.is_a?(String) && /\A[\w-]{16,80}\z/.match?(id)

        fingerprint = [@token, request.path, body]
        if (saved = @writes[id])
          return json(409, error: "同じ送信 ID で異なる内容は送信できません") unless saved[:fingerprint] == fingerprint
          return saved[:response]
        end
        return json(429, error: "操作数の上限です。サーバーを再起動してください") if @writes.size >= 1000

        if request.path == "/api/orders/good_til_date"
          raise ArgumentError unless (body.keys - %w[request_id pair order_type rate amount expires_at]).empty?
          text = body.fetch("expires_at")
          raise ArgumentError unless text.is_a?(String) && /(?:Z|[+-]\d{2}:\d{2})\z/.match?(text)
          deadline = Time.iso8601(text)
          now = @wall_clock.call
          raise ArgumentError unless deadline > now && deadline <= now + 7 * 86_400
          params = order_params(body.reject { |key, _| key == "expires_at" })
          raise ArgumentError unless %w[buy sell].include?(params[:order_type])
          return json(503, error: "GTDの期限監視が起動していません") unless @monitor_thread&.alive?

          result = ioc_executor.submit(params, request_id: id).merge(mode: "emulated_good_til_date", expires_at: deadline.utc.iso8601(6))
          result[:requires_attention] = result[:uncertain]
          response = ioc_response(result)
          @writes[id] = { fingerprint: fingerprint, response: response, gtd: result, next_cancel_at: deadline }
          return response
        end

        if request.path == "/api/orders/immediate_or_cancel"
          raise ArgumentError unless (body.keys - %w[request_id pair order_type rate amount]).empty?
          params = order_params(body)
          raise ArgumentError unless %w[buy sell].include?(params[:order_type])
          result = ioc_executor.call(params, request_id: id)
          response = ioc_response(result)
          @writes[id] = { fingerprint: fingerprint, response: response, ioc: result }
          return response
        end

        params = order_params(body) if request.path == "/api/orders"
        result = begin
          response = if params
                       @client.create_order(**params)
                     else
                       @client.cancel_order(id: request.path.split("/")[3])
                     end
          json(200, response)
        rescue ConfigurationError, APIError => error
          json(422, error: error.message)
        rescue StandardError
          # A timeout, malformed response, or HTTP failure may happen AFTER the
          # exchange accepted the order. Never retry a write automatically.
          json(502, error: "処理結果を確認できません。再送信せず、注文・約定履歴を確認してください。", uncertain: true)
        end
        @writes[id] = { fingerprint: fingerprint, response: result }
        result
      end

      def order_params(body)
        allowed = %w[pair order_type rate amount market_buy_amount stop_loss_rate time_in_force request_id]
        raise ArgumentError unless (body.keys - allowed).empty?

        params = body.reject { |key, _| key == "request_id" }.transform_keys(&:to_sym)
        selected_pair = params.fetch(:pair)
        raise ArgumentError unless selected_pair.is_a?(String) && /\A[a-z0-9]+_jpy\z/.match?(selected_pair)
        raise ArgumentError unless Client::ORDER_TYPES.include?(params[:order_type])

        %i[rate amount market_buy_amount stop_loss_rate].each do |key|
          next unless params.key?(key)
          value = params[key]
          raise ArgumentError unless value.is_a?(String) && /\A\d+(?:\.\d+)?\z/.match?(value) && BigDecimal(value).positive?
        end
        required = case params[:order_type]
                   when "buy", "sell" then %i[rate amount]
                   when "market_buy" then %i[market_buy_amount]
                   else %i[amount]
                   end
        raise ArgumentError unless required.all? { |key| params.key?(key) }
        invalid = case params[:order_type]
                  when "buy", "sell" then %i[market_buy_amount]
                  when "market_buy" then %i[rate amount]
                  else %i[rate market_buy_amount]
                  end
        raise ArgumentError if invalid.any? { |key| params.key?(key) }
        raise ArgumentError if params[:time_in_force] && (params[:time_in_force] != "post_only" || !%w[buy sell].include?(params[:order_type]))
        params
      end

      def ioc_executor
        ImmediateOrCancel.new(@client, before_lookup: lambda {
          # Coincheck limits order-detail reads to one request per second.
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          delay = (@last_ioc_lookup || now - 1.05) + 1.05 - now
          sleep(delay) if delay.positive?
          @last_ioc_lookup = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        })
      end

      def pending_gtd?
        @writes.values.any? { |saved| saved[:gtd] && !saved[:gtd][:terminal] && saved[:gtd][:order_id] }
      end

      def process_gtd
        now = @wall_clock.call
        # One due order per tick keeps other API operations responsive. Failed
        # cancellations are retried after 30 seconds; submissions are never retried.
        saved = @writes.values.find do |entry|
          entry[:gtd] && !entry[:gtd][:terminal] && entry[:gtd][:order_id] && entry[:next_cancel_at] <= now
        end
        return unless saved
        saved[:gtd] = ioc_executor.cancel(saved[:gtd])
        saved[:next_cancel_at] = @wall_clock.call + 30
        saved[:response] = ioc_response(saved[:gtd])
      end

      def gtd_result(id)
        saved = @writes[id]
        return json(404, error: "この接続でのGTD記録がありません") unless saved && saved[:gtd] && saved[:fingerprint].first == @token
        result = ioc_executor.refresh(saved[:gtd])
        result[:requires_attention] = !result[:terminal] && (result[:uncertain] || @wall_clock.call >= Time.iso8601(result[:expires_at]))
        saved[:gtd] = result
        saved[:response] = ioc_response(result)
      end

      def ioc_response(result)
        code = result[:status] == "rejected" ? 422 : result[:terminal] ? 200 : 202
        json(code, result)
      end

      def ioc_result(id)
        saved = @writes[id]
        return json(404, error: "この接続での擬似IOC記録がありません") unless saved && saved[:ioc] && saved[:fingerprint].first == @token
        saved[:ioc] = ioc_executor.refresh(saved[:ioc])
        saved[:response] = ioc_response(saved[:ioc])
      end

      def stream(env, selected_pair, stream_token, login_id)
        socket = Faye::WebSocket.new(env, ["coincheck-local"], ping: 20, max_length: 4096)
        streams = []
        expiry_timer = nil
        socket.on(:open) do |_event|
          unless stream_active?(stream_token, login_id)
            socket.send(JSON.generate(type: @auth.valid?(login_id) ? "session_changed" : "login_required"))
            socket.close
            next
          end
          @sockets[socket] = { token: stream_token, login_id: login_id }
          expiry_timer = EventMachine.add_timer(@auth.remaining(login_id)) do
            socket.send(JSON.generate(type: "login_required"))
            socket.close
          end
          [false, true].each do |private_stream|
            next if private_stream && !@authenticated

            source = private_stream ? "private" : "public"
            connection = RubyCoincheckClient::WebSocket.new(
              pair: selected_pair, private_stream: private_stream,
              login: lambda {
                @api_mutex.synchronize do
                  raise ConfigurationError, "Session changed" unless stream_active?(stream_token, login_id)
                  @client.websocket_login
                end
              },
              on_message: ->(data) { socket.send(JSON.generate(type: "message", source: source, data: data)) if stream_active?(stream_token, login_id) },
              on_status: ->(data) { socket.send(JSON.generate(type: "status", source: source, data: data)) if stream_active?(stream_token, login_id) }
            )
            streams << connection
            connection.start
          end
        end
        socket.on(:close) do |_event|
          EventMachine.cancel_timer(expiry_timer) if expiry_timer
          @sockets.delete(socket)
          streams.each(&:stop)
        end
        socket.rack_response
      end

      def stream_active?(token, login_id)
        valid_token?(token) && @auth.valid?(login_id)
      end

      def valid_token?(token)
        token.is_a?(String) && Rack::Utils.secure_compare(@token, token)
      end

      def pair(request)
        value = request.params.fetch("pair", "btc_jpy")
        raise ArgumentError unless value.is_a?(String) && /\A[a-z0-9]+_jpy\z/.match?(value)
        value
      end

      def json(status, body)
        [status, SECURITY_HEADERS.merge("content-type" => "application/json; charset=utf-8"), [JSON.generate(body)]]
      end
    end
  end
end
