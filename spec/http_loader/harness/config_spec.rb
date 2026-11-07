# typed: false
# frozen_string_literal: true

require 'spec_helper'
require 'http_loader/harness'

RSpec.describe HttpLoader::Harness::Config do
  def config(**overrides)
    described_class.new(connections: 1, target_duration: 0.0, **overrides)
  end

  describe '#validate!' do
    it 'accepts a well-formed configuration without raising' do
      expect { config.validate! }.not_to raise_error
    end

    it 'rejects a zero connections count with the exact message' do
      expect { config(connections: 0).validate! }
        .to raise_error(ArgumentError, '--connections_count must be greater than 0 (got 0)')
    end

    it 'accepts a connections count of 1 (the boundary just above zero)' do
      expect { config(connections: 1).validate! }.not_to raise_error
    end

    it 'rejects a negative target_duration with the exact message' do
      expect { config(target_duration: -1.0).validate! }
        .to raise_error(ArgumentError, '--target_duration must not be negative (got -1.0)')
    end

    it 'accepts a zero target_duration (the disabled sentinel)' do
      expect { config(target_duration: 0.0).validate! }.not_to raise_error
    end
  end
end
