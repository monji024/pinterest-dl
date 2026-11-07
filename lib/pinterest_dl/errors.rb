# frozen_string_literal: true

module PinterestDL
  class Error < StandardError
    attr_reader :url, :status_code, :cause_error

    def initialize(message = nil, url: nil, status_code: nil, cause_error: nil)
      @url = url
      @status_code = status_code
      @cause_error = cause_error
      super(message)
    end
  end

  class ConfigurationError < Error
    def initialize(message = 'Invalid configuration', **kwargs)
      super
    end
  end

  class NetworkError < Error
    def initialize(message = 'A network error occurred', **kwargs)
      super
    end
  end

  class TimeoutError < NetworkError
    def initialize(message = 'Request timed out', **kwargs)
      super
    end
  end


# step-0
