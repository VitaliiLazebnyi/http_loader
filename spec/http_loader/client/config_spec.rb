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
    it 'accepts a well-formed configuration without raising' do
      expect { config.validate! }.not_to raise_error
    end

    # --- strictly-positive flags: zero is rejected, the exact flag name and value appear ---
    {
      connections_count: :connections,
      max_concurrent_connections: :max_concurrent_connections,
      ping_period: :ping_period
    }.each do |flag, attr|
      it "rejects a zero #{flag} with the exact message" do
        expect { config(attr => 0).validate! }
          .to raise_error(ArgumentError, "--#{flag} must be greater than 0 (got 0)")
      end

      it "accepts #{flag} == 1 (the boundary just above zero)" do
        expect { config(attr => 1).validate! }.not_to raise_error
      end
    end

    # --- non-negative flags: a negative value is rejected, zero is accepted ---
    {
      http_loader_timeout: 0.0, connections_per_second: 0, reopen_interval: 0.0,
      read_timeout: 0.0, ramp_up: 0.0, jitter: 0.0, qps_per_connection: 0, slowloris_delay: 0.0
    }.each do |flag, zero|
      it "rejects a negative #{flag} with the exact message" do
        negative = zero.is_a?(Integer) ? -1 : -1.0
        expect { config(flag => negative).validate! }
          .to raise_error(ArgumentError, "--#{flag} must not be negative (got #{negative})")
      end

      it "accepts a zero #{flag} (the disabled-feature sentinel)" do
        expect { config(flag => zero).validate! }.not_to raise_error
      end
    end

    describe 'oversubscription warning' do
      it 'warns on the exact boundary where connections exceed the concurrency cap' do
        expect { config(connections: 3, max_concurrent_connections: 2).validate! }
          .to output(
            '[Client] Warning: --connections_count (3) exceeds --max_concurrent_connections (2); ' \
            "surplus connections are queued and, in keep-alive modes, may never open.\n"
          ).to_stderr
      end

      it 'does not warn when connections equal the concurrency cap' do
        expect { config(connections: 2, max_concurrent_connections: 2).validate! }.not_to output.to_stderr
      end

      it 'does not warn when connections are below the concurrency cap' do
        expect { config(connections: 1, max_concurrent_connections: 2).validate! }.not_to output.to_stderr
      end
    end
  end
end
