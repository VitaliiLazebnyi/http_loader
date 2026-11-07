# typed: strict
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

# RSpec mixes its mock and matcher DSLs, and the suite's own helpers, into every example group at runtime
# (`config.mock_with`, `config.expect_with` and `config.include` in spec/spec_helper.rb); Sorbet's RSpec
# support (sorbet/config) needs the same ancestry declared. RSpec::Matchers comes after the mocks so that
# its `expect`, which also takes a block, wins over the value-only `expect` of
# RSpec::Mocks::ExampleMethods::ExpectHost, as it does at runtime.
class RSpec::Core::ExampleGroup
  include ::RSpec::Mocks::ExampleMethods
  include ::RSpec::Matchers
  include ::RequestMatchers
end
