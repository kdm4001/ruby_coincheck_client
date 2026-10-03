# frozen_string_literal: true

require "json"
require "bigdecimal"
require "digest"
require "fileutils"
require "tempfile"

module RubyCoincheckClient
  module GUI
    # Only timestamps and complete JPY valuations are persisted, never keys or
    # balances. Separate files prevent mixing accounts after changing API keys.
    class PortfolioHistory
      INTERVAL = 300
      RETENTION = 30 * 24 * 60 * 60

      def initialize(directory:, clock: -> { Time.now.to_i })
        @directory = directory
        @clock = clock
      end

      def select_account(key)
        @path = key && @directory && File.join(@directory, "#{Digest::SHA256.hexdigest(key)}.json")
        @samples = nil
      end

      def record(portfolio)
        return unless @path && portfolio[:total_jpy] && portfolio[:missing_rates].empty?
        samples = read_samples
        now = @clock.call
        return if samples.last && now - samples.last.fetch("at") < INTERVAL

        amount = BigDecimal(portfolio.fetch(:total_jpy))
        raise ArgumentError, "Invalid portfolio valuation" unless amount.finite?

        updated = samples.select { |point| point.fetch("at") >= now - RETENTION }
        updated << { "at" => now, "total_jpy" => amount.to_s("F") }
        FileUtils.mkdir_p(@directory, mode: 0o700)
        Tempfile.create([".portfolio-", ".json"], @directory) do |file|
          file.chmod(0o600)
          file.write(JSON.generate(version: 1, samples: updated))
          file.flush
          file.fsync
          File.rename(file.path, @path)
        end
        @samples = updated
      end

      def points(days: 1)
        cutoff = @clock.call - days * 86_400
        read_samples.select { |point| point.fetch("at") >= cutoff }
      end

      private

      def read_samples
        return [] unless @path
        return @samples if @samples
        return @samples = [] unless File.exist?(@path)

        data = JSON.parse(File.read(@path))
        raise ArgumentError, "Invalid portfolio history" unless data["version"] == 1 && data["samples"].is_a?(Array)
        previous = nil
        data["samples"].each do |point|
          at = point.fetch("at")
          amount = point.fetch("total_jpy")
          unless at.is_a?(Integer) && (!previous || at > previous) && amount.is_a?(String) && BigDecimal(amount).finite?
            raise ArgumentError, "Invalid portfolio history"
          end
          previous = at
        end
        @samples = data.fetch("samples")
      end
    end
  end
end
