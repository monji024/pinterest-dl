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

  class ConnectionError < NetworkError
    def initialize(message = 'Connection failed or closed unexpectedly', **kwargs)
      super
    end
  end

  class SSLError < NetworkError
    def initialize(message = 'SSL/TLS handshake or verification failed', **kwargs)
      super
    end
  end

  class RedirectError < NetworkError
    def initialize(message = 'Redirect error', **kwargs)
      super
    end
  end

  class HTTPError < Error
    def initialize(message = 'HTTP request failed', **kwargs)
      super
    end
  end

  class NotFoundError < HTTPError
    def initialize(message = 'The requested resource was not found', **kwargs)
      super(message, status_code: kwargs.fetch(:status_code, 404), **kwargs.except(:status_code))
    end
  end

  class AuthenticationError < HTTPError
    def initialize(message = 'Authentication required (set PinterestDL.configure { |c| c.cookies = ... })', **kwargs)
      super(message, status_code: kwargs.fetch(:status_code, 401), **kwargs.except(:status_code))

# step-1
