# frozen_string_literal: true

require 'ipaddr'
require 'resolv'
require 'uri'

module PinterestDL
  module Security
    PINTEREST_DOMAIN_REGEX = /\A(?:[a-z0-9-]+\.)*pinterest\.(?:com|[a-z]{2,3}(?:\.[a-z]{2})?)\z/i.freeze
    PINIMG_DOMAIN_REGEX = /\A(?:[a-z0-9-]+\.)*pinimg\.com\z/i.freeze
    SHORTENER_DOMAIN_REGEX = /\Apin\.it\z/i.freeze

    PRIVATE_CIDRS = [
      IPAddr.new('0.0.0.0/8'),
      IPAddr.new('10.0.0.0/8'),
      IPAddr.new('100.64.0.0/10'),
      IPAddr.new('127.0.0.0/8'),
      IPAddr.new('169.254.0.0/16'),
      IPAddr.new('172.16.0.0/12'),
      IPAddr.new('192.0.0.0/24'),
      IPAddr.new('192.0.2.0/24'),
      IPAddr.new('192.168.0.0/16'),
      IPAddr.new('198.18.0.0/15'),
      IPAddr.new('198.51.100.0/24'),
      IPAddr.new('203.0.113.0/24'),
      IPAddr.new('224.0.0.0/4'),
      IPAddr.new('240.0.0.0/4'),
      IPAddr.new('::/128'),
      IPAddr.new('::1/128'),

# step-0
