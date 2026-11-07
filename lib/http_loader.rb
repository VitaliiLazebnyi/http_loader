# typed: strong
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'sorbet-runtime'
require_relative 'http_loader/cli'
require_relative 'http_loader/cli_args'
require_relative 'http_loader/client'
require_relative 'http_loader/harness'
require_relative 'http_loader/server'
require_relative 'http_loader/version'

# @author Vitalii Lazebnyi
# @since 0.1.0
# HttpLoader is the main namespace for the high-concurrency Ruby load testing framework.
module HttpLoader
end
