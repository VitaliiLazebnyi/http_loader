# typed: strict
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'ipaddr'

# Addresses for test data from the blocks reserved for documentation, which no real host uses:
# TEST-NET-1 (192.0.2.0/24, RFC 5737) and 2001:db8::/32 (RFC 3849).
module TestAddresses
  extend T::Sig

  # @param host [Integer] the host number within 192.0.2.0/24 (1..254)
  # @return [String] the dotted-quad address
  sig { params(host: Integer).returns(String) }
  def self.ip(host)
    IPAddr.new("192.0.2.#{host}").to_s
  end

  # @param host [Integer] the host number within 2001:db8::/32
  # @return [String] the compressed IPv6 address
  sig { params(host: Integer).returns(String) }
  def self.ipv6(host)
    IPAddr.new("2001:db8::#{host.to_s(16)}").to_s
  end
end
