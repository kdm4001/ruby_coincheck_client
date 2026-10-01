# frozen_string_literal: true

require "json"
require "faye/websocket"
require_relative "client"

module RubyCoincheckClient
  # Call start/stop on the EventMachine reactor. Callbacks run on that reactor.
  # Public payloads are the documented raw arrays; private payloads are hashes.
  class WebSocket
    PUBLIC_URL = "wss://ws-api.coincheck.com/"
    PRIVATE_URL = "wss://stream.coincheck.com/"
    PRIVATE_CHANNELS = %w[order-events execution-events].freeze

    def initialize(pair: "btc_jpy", private_stream: false, client: nil, login: nil,
                   on_message: nil, on_status: nil)
      raise ArgumentError, "invalid pair" unless /\A[a-z0-9]+_jpy\z/.match?(pair)

      @pair = pair
      @private_stream = private_stream
      @login = login || -> { client.websocket_login }
      raise ArgumentError, "client or login is required" if private_stream && !client && !login

      @on_message = on_message || ->(_message) {}
      @on_status = on_status || ->(_status) {}
      @attempts = 0
      @stopped = true
    end

    def start
      return self unless @stopped

      @stopped = false
      connect
      self
    end

    def stop
      @stopped = true
      EventMachine.cancel_timer(@retry_timer) if @retry_timer
      EventMachine.cancel_timer(@handshake_timer) if @handshake_timer
      @socket&.close
      self
    end

    private

    def connect
      return if @stopped

      status("connecting")
      socket = Faye::WebSocket::Client.new(@private_stream ? PRIVATE_URL : PUBLIC_URL, nil, ping: 20)
      @socket = socket
      @handshake_timer = EventMachine.add_timer(15) { socket.close }
      socket.on(:open) do |_event|
        next if @stopped || socket != @socket
        if @private_stream
          # Signing may share a lock with an in-flight REST request. Keep it off
          # the reactor so one request cannot pause all streaming connections.
          EventMachine.defer(
            -> { @login.call rescue nil },
            lambda do |payload|
              next if @stopped || socket != @socket

              if payload
                socket.send(JSON.generate(payload))
              else
                status("error", "WebSocket 認証情報を確認してください")
                stop
              end
            end
          )
        else
          %w[trades orderbook].each do |channel|
            socket.send(JSON.generate(type: "subscribe", channel: "#{@pair}-#{channel}"))
          end
          connected
        end
      end
      socket.on(:message) { |event| receive(socket, event.data) unless @stopped || socket != @socket }
      socket.on(:error) { |_event| status("error", "WebSocket 接続エラー") unless @stopped || socket != @socket }
      socket.on(:close) do |_event|
        next if socket != @socket

        EventMachine.cancel_timer(@handshake_timer) if @handshake_timer
        reconnect unless @stopped
      end
      # A synchronous DNS/connect failure can close Faye's client before the
      # handlers above are installed. Do not leave that connection stuck.
      if socket.ready_state == Faye::WebSocket::API::CLOSED
        EventMachine.cancel_timer(@handshake_timer)
        reconnect unless @stopped
      end
    rescue StandardError
      reconnect unless @stopped
    end

    def receive(socket, raw)
      message = JSON.parse(raw)
      if message.is_a?(Hash) && message["success"] == false
        status("error", "WebSocket の認証・購読が拒否されました。API 権限を確認してください")
        stop
      elsif @private_stream && message.is_a?(Hash) && message.key?("available_channels")
        channels = PRIVATE_CHANNELS & Array(message["available_channels"])
        if channels.empty?
          status("error", "注文・約定イベントの WebSocket 権限がありません")
          stop
        else
          socket.send(JSON.generate(type: "subscribe", channels: channels))
          connected(channels: channels)
        end
      else
        @on_message.call(message)
      end
    rescue JSON::ParserError
      status("error", "WebSocket から不正な JSON を受信しました")
      socket.close
    end

    def connected(**details)
      EventMachine.cancel_timer(@handshake_timer) if @handshake_timer
      @attempts = 0
      status("connected", nil, **details)
    end

    def reconnect
      EventMachine.cancel_timer(@retry_timer) if @retry_timer
      delay = [2**[@attempts, 5].min, 30].min
      @attempts += 1
      status("reconnecting", nil, retry_in: delay)
      @retry_timer = EventMachine.add_timer(delay) { connect }
    end

    def status(state, message = nil, **details)
      @on_status.call({ state: state, message: message }.merge(details))
    end
  end
end
