# typed: false
# frozen_string_literal: true

require 'spec_helper'
require 'http_loader/harness/config'

RSpec.describe HttpLoader::Harness::Config do
  describe '#validate!' do
    it 'accepts a well-formed configuration' do
      expect { described_class.new(connections: 1, target_duration: 0.0).validate! }.not_to raise_error
    end

    it 'rejects non-positive connections' do
      expect { described_class.new(connections: 0).validate! }.to raise_error(ArgumentError, /connections_count/)
    end

    it 'rejects a negative target_duration' do
      expect { described_class.new(connections: 1, target_duration: -1.0).validate! }.to raise_error(ArgumentError, /target_duration/)
    end
  end
end
