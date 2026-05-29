# frozen_string_literal: true


module PinterestDL
  class Error < StandardError
  end

  class NetworkError < Error
    attr_reader :cause_error

    def initialize(message = 'A network error occurred', cause_error: nil)
      @cause_error = cause_error
      super(message)
    end
  end

  class NotFoundError < Error
    def initialize(message = 'The requested resource was not found')
      super
    end
  end

  class RateLimitError < Error
    attr_reader :retry_after

    def initialize(message = 'Rate limited by Pinterest', retry_after: nil)
      @retry_after = retry_after
      super(message)
    end

# step-2
