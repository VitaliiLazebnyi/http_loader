# typed: strict
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'net/http'

# Matchers for the Net::HTTP requests the client sends; included into every example group.
module RequestMatchers
  extend T::Sig
  extend T::Helpers

  requires_ancestor { RSpec::Matchers }

  # Matches a keep-alive request of the given class and path carrying the given user agent and headers.
  #
  # @param klass [Class] the Net::HTTPRequest subclass (Get, Head)
  # @param path [String] the request path
  # @param user_agent [String] the User-Agent header value
  # @param headers [Hash{String => String}] further headers the request must carry
  # @return [RSpec::Matchers::BuiltIn::BaseMatcher] the matcher
  sig do
    params(
      klass: T.class_of(Net::HTTPRequest),
      path: String,
      user_agent: String,
      headers: T::Hash[String, String]
    ).returns(RSpec::Matchers::BuiltIn::BaseMatcher)
  end
  def keep_alive_request(klass, path:, user_agent:, headers:)
    fields = headers.to_h { |name, value| [name.downcase, [value]] }
    fields['connection'] = ['keep-alive']
    fields['user-agent'] = [user_agent]
    an_instance_of(klass).and(having_attributes(path: path, to_hash: a_hash_including(fields)))
  end
end
