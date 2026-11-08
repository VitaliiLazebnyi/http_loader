# typed: strict
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'http_loader/client'

# Builds the open connections the session examples drive.
module ConnectionFactory
  extend T::Sig

  # @param http [Net::HTTP] the Net::HTTP session of the connection
  # @param index [Integer] the worker index
  # @param uri [String] the target
  # @param started [Time] when the connection was opened
  # @return [HttpLoader::Client::Connection] the connection
  sig { params(http: Net::HTTP, index: Integer, uri: String, started: Time).returns(HttpLoader::Client::Connection) }
  def self.build(http, index: 0, uri: 'http://local/', started: Time.at(0))
    HttpLoader::Client::Connection.new(index: index, uri: URI(uri), http: http, started: started)
  end
end
