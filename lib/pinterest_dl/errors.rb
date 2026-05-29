# frozen_string_literal: true


module PinterestDL
  class Error < StandardError
  end

  class NetworkError < Error
    attr_reader :cause_error

# step-0
