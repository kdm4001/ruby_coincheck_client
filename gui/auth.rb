# frozen_string_literal: true

require "openssl"
require "securerandom"
require "rack/utils"

module RubyCoincheckClient
  module GUI
    # Local GUI authentication, independent of Coincheck credentials. State is
    # held in this process; no unauthenticated setup or password-reset endpoint.
    class Auth
      COOKIE = "coincheck_gui_session"
      SESSION_SECONDS = 8 * 60 * 60
      MAX_FAILURES = 5
      RETRY_SECONDS = 60
      MAX_SESSIONS = 16

      def initialize(password, session_seconds: SESSION_SECONDS, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        unless password.is_a?(String) && password.length >= 12 && password.bytesize <= 1024 && !password.strip.empty?
          raise ArgumentError, "GUI password must be at least 12 characters and at most 1024 bytes"
        end
        unless session_seconds.is_a?(Integer) && (3600..604_800).cover?(session_seconds)
          raise ArgumentError, "GUI session duration must be between 1 and 168 hours"
        end
        @session_seconds = session_seconds
        @clock = clock
        @salt = SecureRandom.random_bytes(32)
        @password_hash = digest(password)
        @sessions = {}
        @failures = []
        @mutex = Mutex.new
      end

      def login(password, previous_id: nil)
        @mutex.synchronize do
          now = @clock.call
          @failures.reject! { |at| at <= now - RETRY_SECONDS }
          @sessions.delete_if { |_id, expires| expires <= now }
          return [:limited, nil] if @failures.size >= MAX_FAILURES

          valid = password.is_a?(String) && password.bytesize <= 1024 &&
                  Rack::Utils.secure_compare(@password_hash, digest(password))
          unless valid
            @failures << now
            return [:invalid, nil]
          end
          return [:limited, nil] if @sessions.size >= MAX_SESSIONS && !@sessions.key?(previous_id)

          @failures.clear
          @sessions.delete(previous_id)
          id = SecureRandom.hex(32)
          @sessions[id] = now + @session_seconds
          [:ok, id]
        end
      end

      def remaining(id)
        @mutex.synchronize { [@sessions.fetch(id, 0) - @clock.call, 0].max }
      end

      def valid?(id)
        remaining(id).positive?
      end

      def logout(id)
        @mutex.synchronize { @sessions.delete(id) }
      end

      private

      def digest(password)
        OpenSSL::KDF.pbkdf2_hmac(password, salt: @salt, iterations: 600_000, length: 32, hash: "SHA256")
      end
    end
  end
end
