# typed: true
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'spec_helper'

RSpec.describe(HttpLoader::CliArgs) do
  describe '.split_list' do
    it 'splits on commas, trims surrounding whitespace, and drops empty tokens' do
      expect(HttpLoader::CliArgs.split_list(' a , b ,, c,')).to(eq(%w[a b c]))
    end

    it 'returns an empty array for a blank value' do
      expect(HttpLoader::CliArgs.split_list('')).to(eq([]))
    end

    it 'keeps a single token intact' do
      expect(HttpLoader::CliArgs.split_list('http://only')).to(eq(['http://only']))
    end
  end

  describe HttpLoader::CliArgs::ClientParser do
    it 'documents every flag with its description in the generated help text' do
      descriptions = [
        'Total connection count',
        'Use HTTPS natively',
        'Comma-separated target URLs',
        'Verbose logging',
        'Enable keep-alive pings',
        'Seconds between pings',
        'Keep-alive budget in seconds',
        'Connection ramp rate',
        'Concurrency cap',
        'Reopen closed connections',
        'Delay before reopening',
        'Socket read timeout',
        'User-Agent header',
        'Randomize sleep durations',
        'Track HTTP status codes',
        'Ramp-up window in seconds',
        'Comma-separated source IPs',
        'Comma-separated proxy URIs',
        'Per-connection QPS cap',
        'Repeatable Key: Value header',
        'Slowloris byte gap in seconds',
        'Accepted but ignored by the client subprocess',
        'Accepted but ignored; honoured by the harness only'
      ]
      help = CliParsing.client_help
      expect(descriptions.reject { |description| help.include?(description) }).to(eq([]))
    end

    it 'parses the core connectivity and URL flags' do
      expect(CliParsing.client(['--connections_count=42', '--https', '--url=http://a, http://b', '--verbose']))
        .to(eq(headers: {}, connections: 42, use_https: true, target_urls: ['http://a', 'http://b'], verbose: true))
    end

    it 'leaves every option unset when no flag is supplied' do
      expect(CliParsing.client([])).to(eq(headers: {}))
    end

    it 'parses ping enablement and period' do
      expect(CliParsing.client(['--ping', '--ping_period=2.5'])).to(eq(headers: {}, ping: true, ping_period: 2.5))
    end

    it 'parses the negated --no-ping form to false' do
      expect(CliParsing.client(['--no-ping'])).to(eq(headers: {}, ping: false))
    end

    it 'parses the timeout, rate, and concurrency thresholds' do
      expect(
        CliParsing.client(
          [
            '--http_loader_timeout=1.5',
            '--connections_per_second=10',
            '--max_concurrent_connections=5'
          ]
        )
      ).to(eq(headers: {}, http_loader_timeout: 1.5, connections_per_second: 10, max_concurrent_connections: 5))
    end

    it 'parses the advanced connection-lifecycle flags' do
      expect(CliParsing.client(['--reopen_closed_connections', '--reopen_interval=3.0', '--read_timeout=4.0']))
        .to(eq(headers: {}, reopen_closed_connections: true, reopen_interval: 3.0, read_timeout: 4.0))
    end

    it 'parses the tracking and obfuscation flags' do
      expect(CliParsing.client(['--user_agent=Foo/1', '--jitter=0.5', '--track_status_codes']))
        .to(eq(headers: {}, user_agent: 'Foo/1', jitter: 0.5, track_status_codes: true))
    end

    it 'parses the IP-binding, proxy, and ramp-up flags' do
      bind_ips = "--bind_ips=#{TestAddresses.ip(1)}, #{TestAddresses.ip(2)}"
      expect(CliParsing.client(['--ramp_up=2.0', bind_ips, '--proxy_pool=http://p1, http://p2']))
        .to(eq(
              headers: {},
              ramp_up: 2.0,
              bind_ips: [TestAddresses.ip(1), TestAddresses.ip(2)],
              proxy_pool: ['http://p1', 'http://p2']
            ))
    end

    it 'parses the slowloris flags' do
      expect(CliParsing.client(['--qps_per_connection=7', '--slowloris_delay=0.2']))
        .to(eq(headers: {}, qps_per_connection: 7, slowloris_delay: 0.2))
    end

    it 'accepts but discards --export_json and --target_duration (the client ignores them)' do
      expect(CliParsing.client(['--export_json=out.json', '--target_duration=5.0'])).to(eq(headers: {}))
    end

    it 'routes each --headers occurrence into the accumulated header map' do
      expect(CliParsing.client(['--headers=X-A: 1', '--headers=X-B: 2']))
        .to(eq(headers: { 'X-A' => '1', 'X-B' => '2' }))
    end

    describe '.parse_headers' do
      it 'parses a single Key: Value header, trimming whitespace from both ends of key and value' do
        expect(CliParsing.headers_for(' X-Foo :  bar ')).to(eq('X-Foo' => 'bar'))
      end

      it 'splits only on the first colon, preserving colons in the value' do
        expect(CliParsing.headers_for('X-Time: 10:30:00')).to(eq('X-Time' => '10:30:00'))
      end

      it 'accumulates multiple headers across invocations' do
        options = { headers: {} }
        HttpLoader::CliArgs::ClientParser.parse_headers('A: 1', options)
        HttpLoader::CliArgs::ClientParser.parse_headers('B: 2', options)
        expect(options).to(eq(headers: { 'A' => '1', 'B' => '2' }))
      end

      it 'warns (quoting the raw entry) and skips an entry with no colon', :aggregate_failures do
        expect { expect(CliParsing.headers_for('nocolon')).to(eq({})) }
          .to(output("[Client] Ignoring malformed --headers entry (expected 'Key: Value'): \"nocolon\"\n").to_stderr)
      end

      it 'warns (quoting the raw entry) and skips an entry with an empty key', :aggregate_failures do
        expect { expect(CliParsing.headers_for(': value')).to(eq({})) }
          .to(output("[Client] Ignoring --headers entry with empty key: \": value\"\n").to_stderr)
      end

      it 'warns (quoting the raw entry) and skips a CR/LF in the value (header-injection guard)', :aggregate_failures do
        value = "X-Evil: a\r\nInjected: 1"
        expect { expect(CliParsing.headers_for(value)).to(eq({})) }
          .to(output("[Client] Ignoring --headers entry with CR/LF: #{value.inspect}\n").to_stderr)
      end

      it 'rejects a CR/LF embedded in the key as well as in the value', :aggregate_failures do
        expect { expect(CliParsing.headers_for("X\r\nY: ok")).to(eq({})) }
          .to(output(%r{CR/LF}).to_stderr)
      end

      it 'rejects a lone LF', :aggregate_failures do
        expect { expect(CliParsing.headers_for("X: a\nb")).to(eq({})) }
          .to(output(%r{CR/LF}).to_stderr)
      end

      it 'rejects a lone CR', :aggregate_failures do
        expect { expect(CliParsing.headers_for("X: a\rb")).to(eq({})) }
          .to(output(%r{CR/LF}).to_stderr)
      end
    end
  end

  describe HttpLoader::CliArgs::HarnessParser do
    it 'documents every structural flag with its description in the generated help text' do
      descriptions = [
        'Total connection count',
        'Use HTTPS natively',
        'Comma-separated target URLs',
        'Write the JSON run report to FILE',
        'Stop after S seconds'
      ]
      help = CliParsing.harness_help
      expect(descriptions.reject { |description| help.include?(description) }).to(eq([]))
    end

    it 'parses the harness structural flags' do
      expect(CliParsing.harness(['--connections_count=100', '--https', '--url=http://a, http://b']))
        .to(eq(connections: 100, use_https: true, target_urls: ['http://a', 'http://b']))
    end

    it 'parses the harness-only extras' do
      expect(CliParsing.harness(['--export_json=out.json', '--target_duration=30.0']))
        .to(eq(export_json: 'out.json', target_duration: 30.0))
    end

    it 'tolerates every client-only flag without recording or rejecting it' do
      client_flags = %W[
        --verbose
        --ping
        --ping_period=1
        --http_loader_timeout=1
        --connections_per_second=1
        --max_concurrent_connections=1
        --reopen_closed_connections
        --reopen_interval=1
        --read_timeout=1
        --user_agent=A
        --jitter=1
        --track_status_codes
        --ramp_up=1
        --bind_ips=#{TestAddresses.ip(1)}
        --proxy_pool=http://p
        --qps_per_connection=1
        --headers=A:1
        --slowloris_delay=1
      ]
      expect(CliParsing.harness(client_flags + ['--connections_count=5'])).to(eq(connections: 5))
    end

    it 'lists every client-only flag the harness must tolerate' do
      expected = %w[--verbose --headers=LIST --slowloris_delay=S]
      expect(expected & HttpLoader::CliArgs::HarnessParser::IGNORED_CLIENT_FLAGS).to(eq(expected))
    end
  end

  describe HttpLoader::CliArgs::ClientOptions do
    it 'gives each parse its own header map' do
      first = HttpLoader::CliArgs::ClientOptions.defaults
      expect(first.fetch(:headers)).not_to(be(HttpLoader::CliArgs::ClientOptions.defaults.fetch(:headers)))
    end

    it 'defaults the concurrency cap to the connection count' do
      options = HttpLoader::CliArgs::ClientOptions.defaults.merge(connections: 7)
      expect(HttpLoader::CliArgs::ClientOptions.config(options).max_concurrent_connections).to(eq(7))
    end

    it 'keeps an explicit concurrency cap' do
      options = HttpLoader::CliArgs::ClientOptions.defaults.merge(connections: 7, max_concurrent_connections: 3)
      expect(HttpLoader::CliArgs::ClientOptions.config(options).max_concurrent_connections).to(eq(3))
    end

    it 'builds the configuration from every default' do
      expect(HttpLoader::CliArgs::ClientOptions.config(HttpLoader::CliArgs::ClientOptions.defaults).serialize)
        .to(eq(ConfigFactory.client.serialize))
    end

    it 'rejects a wrongly typed option value' do
      options = HttpLoader::CliArgs::ClientOptions.defaults.merge(connections: '7')
      expect { HttpLoader::CliArgs::ClientOptions.config(options) }
        .to(raise_error(TypeError))
    end

    it 'rejects an unknown option' do
      options = HttpLoader::CliArgs::ClientOptions.defaults.merge(bogus: 1)
      expect { HttpLoader::CliArgs::ClientOptions.config(options) }
        .to(raise_error(TypeError))
    end
  end

  describe HttpLoader::CliArgs::HarnessOptions do
    it 'builds the configuration from the options and the forwarded client flags' do
      options = HttpLoader::CliArgs::HarnessOptions::DEFAULTS.merge(connections: 9, export_json: 'run.json')
      expect(HttpLoader::CliArgs::HarnessOptions.config(options, ['--verbose']).serialize)
        .to(eq(
              'connections' => 9,
              'target_urls' => [],
              'use_https' => false,
              'client_args' => ['--verbose'],
              'export_json' => 'run.json',
              'target_duration' => 0.0
            ))
    end

    it 'rejects a wrongly typed option value' do
      options = HttpLoader::CliArgs::HarnessOptions::DEFAULTS.merge(target_duration: 1)
      expect { HttpLoader::CliArgs::HarnessOptions.config(options, []) }
        .to(raise_error(TypeError))
    end
  end
end
