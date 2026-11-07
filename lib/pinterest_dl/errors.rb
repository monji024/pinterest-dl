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
    end
  end

  class ForbiddenError < HTTPError
    def initialize(message = 'Access to the requested resource was forbidden (HTTP 403)', **kwargs)
      super(message, status_code: kwargs.fetch(:status_code, 403), **kwargs.except(:status_code))
    end
  end

  class RateLimitError < HTTPError
    attr_reader :retry_after

    def initialize(message = 'Rate limited by Pinterest', retry_after: nil, **kwargs)
      @retry_after = retry_after
      super(message, status_code: kwargs.fetch(:status_code, 429), **kwargs.except(:status_code))
    end
  end

  class RangeNotSatisfiableError < HTTPError
    attr_reader :content_range

    def initialize(message = 'Requested byte range is not satisfiable (HTTP 416)', content_range: nil, **kwargs)
      @content_range = content_range
      super(message, status_code: kwargs.fetch(:status_code, 416), **kwargs.except(:status_code))
    end
  end

  class ServerError < HTTPError
    def initialize(message = 'Pinterest server returned an error', **kwargs)
      super
    end
  end

# step-2
