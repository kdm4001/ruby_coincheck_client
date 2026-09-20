# frozen_string_literal: true

module RubyCoincheckClient
  class Error < StandardError; end

  class ConfigurationError < Error; end

  class ResponseError < Error
    attr_reader :body

    def initialize(message, body: nil)
      @body = body
      super(message)
    end
  end

  class HTTPError < ResponseError
    attr_reader :status, :headers

    def initialize(response, body:)
      @status = response.code.to_i
      @headers = response.to_hash

      detail = body.is_a?(Hash) ? body["error"] : nil
      message = "Coincheck API returned HTTP #{@status}"
      message = "#{message}: #{detail}" if detail

      super(message, body: body)
    end
  end

  class APIError < ResponseError
    def initialize(body)
      detail = body.is_a?(Hash) ? body["error"] : nil
      message = detail ? "Coincheck API error: #{detail}" : "Coincheck API request failed"
      super(message, body: body)
    end
  end
end
