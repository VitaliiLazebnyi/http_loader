# typed: false
# frozen_string_literal: true

require 'spec_helper'
require 'http_loader/client/config'

RSpec.describe HttpLoader::Client::Config do
  def config(**overrides)
    defaults = {
      connections: 1, ping_period: 1, max_concurrent_connections: 1, http_loader_timeout: 0.0,
      connections_per_second: 0, reopen_interval: 0.0, read_timeout: 0.0, ramp_up: 0.0,
      jitter: 0.0, qps_per_connection: 0, slowloris_delay: 0.0
    }
    described_class.new(**defaults, **overrides)
  end

  describe '#validate!' do
    it 'accepts a well-formed configuration' do
      expect { config.validate! }.not_to raise_error
    end

    it 'rejects non-positive connections_count' do
      expect { config(connections: 0).validate! }.to raise_error(ArgumentError, /connections_count must be greater than 0/)
    end

    it 'rejects non-positive max_concurrent_connections' do
      expect { config(max_concurrent_connections: 0).validate! }.to raise_error(ArgumentError, /max_concurrent_connections/)
    end

    it 'rejects non-positive ping_period' do
      expect { config(ping_period: 0).validate! }.to raise_error(ArgumentError, /ping_period/)
    end

    it 'rejects negative jitter' do
      expect { config(jitter: -0.5).validate! }.to raise_error(ArgumentError, /jitter must not be negative/)
    end

    it 'rejects a negative timing flag' do
      expect { config(reopen_interval: -5.0).validate! }.to raise_error(ArgumentError, /reopen_interval/)
    end

    it 'permits zero for the disabled-feature sentinels' do
      expect { config(http_loader_timeout: 0.0, qps_per_connection: 0, slowloris_delay: 0.0).validate! }.not_to raise_error
    end

    it 'warns (without raising) when connections exceed max_concurrent_connections' do
      expect { config(connections: 5, max_concurrent_connections: 2).validate! }.to output(/exceeds/).to_stderr
    end
  end
end
