# typed: true
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'spec_helper'

RSpec.describe(HttpLoader::Client::Config) do
  describe '#validate' do
    it 'accepts a well-formed configuration without raising' do
      expect { ConfigFactory.client.validate }
        .not_to(raise_error)
    end

    describe 'strictly-positive flags' do
      let(:flags) do
        {
          connections_count: [:connections, 0, 1],
          max_concurrent_connections: [:max_concurrent_connections, 0, 1],
          ping_period: [:ping_period, 0.0, 1.0]
        }
      end

      it 'rejects a zero value of each with the exact flag name and value', :aggregate_failures do
        flags.each do |flag, (attr, zero, _one)|
          expect { ConfigFactory.client(attr => zero).validate }
            .to(raise_error(ArgumentError, "--#{flag} must be greater than 0 (got #{zero})"))
        end
      end

      it 'accepts 1 for each (the boundary just above zero)', :aggregate_failures do
        flags.each_value do |attr, _zero, one|
          expect { ConfigFactory.client(:connections => 1, attr => one).validate }
            .not_to(raise_error)
        end
      end
    end

    describe 'non-negative flags' do
      let(:zeros) do
        {
          http_loader_timeout: 0.0,
          connections_per_second: 0,
          reopen_interval: 0.0,
          read_timeout: 0.0,
          ramp_up: 0.0,
          jitter: 0.0,
          qps_per_connection: 0,
          slowloris_delay: 0.0
        }
      end

      it 'rejects a negative value of each with the exact flag name and value', :aggregate_failures do
        zeros.each do |flag, zero|
          negative = zero.is_a?(Integer) ? -1 : -1.0
          expect { ConfigFactory.client(flag => negative).validate }
            .to(raise_error(ArgumentError, "--#{flag} must not be negative (got #{negative})"))
        end
      end

      it 'accepts zero for each (the disabled-feature sentinel)', :aggregate_failures do
        zeros.each do |flag, zero|
          expect { ConfigFactory.client(flag => zero).validate }
            .not_to(raise_error)
        end
      end
    end

    describe 'oversubscription warning' do
      it 'warns on the exact boundary where connections exceed the concurrency cap' do
        expect { ConfigFactory.client(connections: 3, max_concurrent_connections: 2).validate }
          .to(output(
            '[Client] Warning: --connections_count (3) exceeds --max_concurrent_connections (2); ' \
              "surplus connections are queued and, in keep-alive modes, may never open.\n"
          ).to_stderr)
      end

      it 'does not warn when connections equal the concurrency cap' do
        expect { ConfigFactory.client(connections: 2, max_concurrent_connections: 2).validate }
          .not_to(output.to_stderr)
      end

      it 'does not warn when connections are below the concurrency cap' do
        expect { ConfigFactory.client(connections: 1, max_concurrent_connections: 2).validate }
          .not_to(output.to_stderr)
      end
    end
  end

  describe '#request_headers' do
    it 'is keep-alive, the User-Agent, then the --headers ones, in that order' do
      config = ConfigFactory.client(user_agent: 'UA/2', headers: { 'X-A' => '1' })
      expect(config.request_headers.to_a).to(eq([%w[Connection keep-alive], %w[User-Agent UA/2], %w[X-A 1]]))
    end

    it 'lets a --headers one replace a default of the same name' do
      config = ConfigFactory.client(headers: { 'Connection' => 'close' })
      expect(config.request_headers).to(eq('Connection' => 'close', 'User-Agent' => 'Keep-Alive Test'))
    end
  end
end
