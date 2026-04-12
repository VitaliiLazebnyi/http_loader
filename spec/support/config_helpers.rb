# typed: true
# frozen_string_literal: true

require 'keep_alive/client/config'
require 'keep_alive/harness/config'

module ConfigHelpers
  def build_client(**)
    KeepAlive::Client.new(KeepAlive::Client::Config.new(**))
  end

  def build_harness(**)
    KeepAlive::Harness.new(KeepAlive::Harness::Config.new(**))
  end
end

RSpec.configure do |config|
  config.include ConfigHelpers
end
