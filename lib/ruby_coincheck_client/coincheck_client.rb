# frozen_string_literal: true

require_relative "version"
require_relative "errors"
require_relative "client"

# Backwards-compatible top-level constant used by versions 0.x.
CoincheckClient = RubyCoincheckClient::Client unless defined?(CoincheckClient)
