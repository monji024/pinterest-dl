# frozen_string_literal: true

# Monji024
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
  end

  class AuthenticationError < Error
    def initialize(message = 'Authentication required (set PinterestDL.configure { |c| c.cookies = ... })')
      super
    end
  end

  class InvalidURLError < Error
    def initialize(message = 'The given URL does not look like a valid Pinterest URL')
      super
    end
  end

  class DownloadError < Error
    def initialize(message = 'Failed to download file')
      super
    end
  end
end
