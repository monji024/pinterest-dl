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

# step-1
