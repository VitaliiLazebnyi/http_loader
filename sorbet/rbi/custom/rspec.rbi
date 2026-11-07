# typed: strict
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

# RSpec mixes its mock and matcher DSLs into every example group at runtime (`config.mock_with` and
# `config.expect_with` in spec/spec_helper.rb); Sorbet's RSpec support (sorbet/config) needs the same
# ancestry declared. RSpec::Matchers comes last so that its `expect`, which also takes a block, wins over
# the value-only `expect` of RSpec::Mocks::ExampleMethods::ExpectHost, as it does at runtime.
class RSpec::Core::ExampleGroup
  include ::RSpec::Mocks::ExampleMethods
  include ::RSpec::Matchers
end
