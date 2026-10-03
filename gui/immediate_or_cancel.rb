# frozen_string_literal: true

require "bigdecimal"
require "time"
require_relative "../lib/ruby_coincheck_client"

module RubyCoincheckClient
  module GUI
    # Best-effort IOC: submit once, immediately cancel, then inspect. Callers
    # serialize the whole operation with other private API calls/nonces.
    class ImmediateOrCancel
      STATES = {
        "NEW" => "open", "PARTIALLY_FILLED" => "open",
        "FILLED" => "filled", "CANCELED" => "canceled",
        "PARTIALLY_FILLED_CANCELED" => "canceled", "EXPIRED" => "expired",
        "PARTIALLY_FILLED_EXPIRED" => "expired"
      }.freeze
      TERMINAL = %w[filled canceled expired rejected].freeze

      def initialize(client, before_lookup: -> {})
        @client = client
        @before_lookup = before_lookup
      end

      def call(params, request_id:)
        cancel(submit(params, request_id: request_id))
      end

      def submit(params, request_id:)
        result = {
          request_id: request_id, mode: "emulated_immediate_or_cancel",
          pair: params.fetch(:pair), order_type: params.fetch(:order_type),
          requested_amount: params.fetch(:amount), rate: params.fetch(:rate),
          order_id: nil, status: "unknown", cancel_request: "not_sent",
          executed_amount: nil, remaining_amount: nil, canceled_amount: nil, expired_amount: nil,
          terminal: false, uncertain: true, requires_attention: true
        }
        begin
          response = @client.create_order(**params)
          id = response.fetch("id")
          raise ResponseError, "Invalid order ID" unless /\A[1-9]\d*\z/.match?(id.to_s)
          result[:order_id] = id.to_s
        rescue ConfigurationError, APIError
          return result.merge(status: "rejected", terminal: true, uncertain: false, requires_attention: false)
        rescue StandardError
          return result # Never guess an ID or repeat an ambiguous submission.
        end

        result.merge(status: "open", uncertain: false)
      end

      def cancel(result)
        return result if result[:terminal] || !result[:order_id]
        # No polling, sleep, or UI interaction between acceptance and cancel.
        begin
          response = @client.cancel_order(id: result[:order_id])
          result[:cancel_request] = response["success"] == true && response["id"].to_s == result[:order_id] ? "accepted" : "unknown"
        rescue ConfigurationError, APIError
          result[:cancel_request] = "rejected"
        rescue StandardError
          result[:cancel_request] = "unknown"
        end
        refresh(result)
      end

      # A read-only reconciliation; never resubmit or cancel on a GET/replay.
      def refresh(result)
        return result if result[:terminal] || !result[:order_id]
        @before_lookup.call
        order = @client.order(id: result[:order_id])
        unless order.fetch("id").to_s == result[:order_id] && order.fetch("pair") == result[:pair] && order.fetch("order_type") == result[:order_type]
          raise ResponseError, "Order identity mismatch"
        end
        status = STATES.fetch(order.fetch("status"))
        amount = decimal(order.fetch("amount"))
        executed = decimal(order.fetch("executed_amount"))
        expired = decimal(order.fetch("expired_amount"))
        remaining = amount - executed - expired
        unless amount == decimal(result[:requested_amount]) && remaining >= 0 &&
               (status != "filled" || executed == amount) && (status != "expired" || remaining.zero?)
          raise ResponseError, "Inconsistent order quantities"
        end
        terminal = TERMINAL.include?(status)
        result.merge(status: status, exchange_status: order["status"],
                     executed_amount: executed.to_s("F"), expired_amount: expired.to_s("F"),
                     canceled_amount: (status == "canceled" ? remaining : BigDecimal("0")).to_s("F"),
                     remaining_amount: (terminal ? BigDecimal("0") : remaining).to_s("F"),
                     terminal: terminal, uncertain: false, requires_attention: !terminal,
                     checked_at: Time.now.utc.iso8601)
      rescue StandardError
        result.merge(status: "unknown", terminal: false, uncertain: true, requires_attention: true,
                     executed_amount: nil, expired_amount: nil, canceled_amount: nil, remaining_amount: nil,
                     exchange_status: nil, checked_at: nil)
      end

      private

      def decimal(value)
        raise ResponseError, "Invalid quantity" unless value.is_a?(String) && /\A\d+(?:\.\d+)?\z/.match?(value)
        BigDecimal(value)
      end
    end
  end
end
