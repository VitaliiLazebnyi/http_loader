# typed: strong
# frozen_string_literal: true

require 'sorbet-runtime'
require_relative 'http_loader/version'
require_relative 'http_loader/server'
require_relative 'http_loader/client'
require_relative 'http_loader/harness'

# HttpLoader is the main namespace for the high-concurrency Ruby load testing framework.
module HttpLoader
end
