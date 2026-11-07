# typed: strict
# frozen_string_literal: true
# Copyright (c) 2026 Vitalii Lazebnyi

# RSpec mixes its matcher and mock DSLs into every example group at runtime (`config.expect_with` and
# `config.mock_with` in spec_helper.rb); Sorbet's RSpec support needs the same ancestry declared.
class RSpec::Core::ExampleGroup
  include ::RSpec::Matchers
  include ::RSpec::Mocks::ExampleMethods
end
