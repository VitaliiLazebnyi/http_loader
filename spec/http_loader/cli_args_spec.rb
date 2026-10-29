# typed: false
# frozen_string_literal: true

require 'spec_helper'
require 'optparse'
require 'http_loader/cli_args'

RSpec.describe HttpLoader::CliArgs do
  describe HttpLoader::CliArgs::ClientParser do
    # Wire the full ClientParser into a fresh OptionParser and parse argv into an options hash.
    def parse(argv)
      options = { headers: {} }
      OptionParser.new { |opts| described_class.parse(opts, options) }.parse!(argv)
      options
    end

    # The rendered --help text, which carries every registered flag's description.
    def help_text
      OptionParser.new { |opts| described_class.parse(opts, { headers: {} }) }.to_s
    end

    it 'documents every flag with its description in the generated help text' do
      help = help_text
      [
        'Total connection count', 'Use HTTPS natively', 'Comma-separated target URLs', 'Verbose logging',
        'Enable keep-alive pings', 'Seconds between pings', 'Keep-alive budget in seconds',
        'Connection ramp rate', 'Concurrency cap', 'Reopen closed connections', 'Delay before reopening',
        'Socket read timeout', 'User-Agent header', 'Randomize sleep durations', 'Track HTTP status codes',
        'Ramp-up window in seconds', 'Comma-separated source IPs', 'Comma-separated proxy URIs',
        'Per-connection QPS cap', 'Repeatable Key: Value header', 'Slowloris byte gap in seconds',
        'Accepted but ignored by the client subprocess', 'Accepted but ignored; honoured by the harness only'
      ].each { |description| expect(help).to include(description) }
    end

    it 'parses the core connectivity and URL flags' do
      opts = parse(['--connections_count=42', '--https', '--url=http://a, http://b', '--verbose'])
      expect(opts[:connections]).to eq(42)
      expect(opts[:use_https]).to be(true)
      expect(opts[:target_urls]).to eq(['http://a', 'http://b'])
      expect(opts[:verbose]).to be(true)
    end

    it 'leaves core flags unset when they are not supplied' do
      opts = parse([])
      expect(opts).not_to have_key(:connections)
      expect(opts).not_to have_key(:use_https)
      expect(opts).not_to have_key(:verbose)
    end

    it 'parses ping enablement and period' do
      opts = parse(['--ping', '--ping_period=2.5'])
      expect(opts[:ping]).to be(true)
      expect(opts[:ping_period]).to eq(2.5)
    end

    it 'parses the negated --no-ping form to false' do
      expect(parse(['--no-ping'])[:ping]).to be(false)
    end

    it 'parses the timeout, rate, and concurrency thresholds' do
      opts = parse(['--http_loader_timeout=1.5', '--connections_per_second=10', '--max_concurrent_connections=5'])
      expect(opts[:http_loader_timeout]).to eq(1.5)
      expect(opts[:connections_per_second]).to eq(10)
      expect(opts[:max_concurrent_connections]).to eq(5)
    end

    it 'parses the advanced connection-lifecycle flags' do
      opts = parse(['--reopen_closed_connections', '--reopen_interval=3.0', '--read_timeout=4.0'])
      expect(opts[:reopen_closed_connections]).to be(true)
      expect(opts[:reopen_interval]).to eq(3.0)
      expect(opts[:read_timeout]).to eq(4.0)
    end

    it 'parses the tracking and obfuscation flags' do
      opts = parse(['--user_agent=Foo/1', '--jitter=0.5', '--track_status_codes'])
      expect(opts[:user_agent]).to eq('Foo/1')
      expect(opts[:jitter]).to eq(0.5)
      expect(opts[:track_status_codes]).to be(true)
    end

    it 'parses the IP-binding, proxy, and ramp-up flags' do
      opts = parse(['--ramp_up=2.0', '--bind_ips=1.1.1.1, 2.2.2.2', '--proxy_pool=http://p1, http://p2'])
      expect(opts[:ramp_up]).to eq(2.0)
      expect(opts[:bind_ips]).to eq(['1.1.1.1', '2.2.2.2'])
      expect(opts[:proxy_pool]).to eq(['http://p1', 'http://p2'])
    end

    it 'parses the slowloris flags' do
      opts = parse(['--qps_per_connection=7', '--slowloris_delay=0.2'])
      expect(opts[:qps_per_connection]).to eq(7)
      expect(opts[:slowloris_delay]).to eq(0.2)
    end

    it 'accepts but discards --export_json and --target_duration (the client ignores them)' do
      opts = parse(['--export_json=out.json', '--target_duration=5.0'])
      expect(opts).not_to have_key(:export_json)
      expect(opts).not_to have_key(:target_duration)
    end

    describe '.split_list' do
      it 'splits on commas, trims surrounding whitespace, and drops empty tokens' do
        expect(described_class.split_list(' a , b ,, c,')).to eq(%w[a b c])
      end

      it 'returns an empty array for a blank value' do
        expect(described_class.split_list('')).to eq([])
      end

      it 'keeps a single token intact' do
        expect(described_class.split_list('http://only')).to eq(['http://only'])
      end
    end

    describe '.parse_headers' do
      def headers_for(value)
        options = { headers: {} }
        described_class.parse_headers(value, options)
        options[:headers]
      end

      it 'parses a single Key: Value header, trimming whitespace from both ends of key and value' do
        expect(headers_for(' X-Foo :  bar ')).to eq('X-Foo' => 'bar')
      end

      it 'splits only on the first colon, preserving colons in the value' do
        expect(headers_for('X-Time: 10:30:00')).to eq('X-Time' => '10:30:00')
      end

      it 'accumulates multiple headers across invocations' do
        options = { headers: {} }
        described_class.parse_headers('A: 1', options)
        described_class.parse_headers('B: 2', options)
        expect(options[:headers]).to eq('A' => '1', 'B' => '2')
      end

      it 'warns (quoting the raw entry) and skips an entry with no colon, leaving headers untouched' do
        options = { headers: {} }
        expect { described_class.parse_headers('nocolon', options) }
          .to output("[Client] Ignoring malformed --headers entry (expected 'Key: Value'): \"nocolon\"\n").to_stderr
        expect(options[:headers]).to be_empty
      end

      it 'warns (quoting the raw entry) and skips an entry with an empty key' do
        options = { headers: {} }
        expect { described_class.parse_headers(': value', options) }
          .to output("[Client] Ignoring --headers entry with empty key: \": value\"\n").to_stderr
        expect(options[:headers]).to be_empty
      end

      it 'warns (quoting the raw entry) and skips a CR/LF in the value (header-injection guard)' do
        options = { headers: {} }
        val = "X-Evil: a\r\nInjected: 1"
        expect { described_class.parse_headers(val, options) }
          .to output("[Client] Ignoring --headers entry with CR/LF: #{val.inspect}\n").to_stderr
        expect(options[:headers]).to be_empty
      end

      it 'rejects a CR/LF embedded in the key as well as in the value' do
        options = { headers: {} }
        expect { described_class.parse_headers("X\r\nY: ok", options) }.to output(%r{CR/LF}).to_stderr
        expect(options[:headers]).to be_empty
      end

      it 'rejects a lone LF and a lone CR, not only the CRLF pair' do
        lf = { headers: {} }
        cr = { headers: {} }
        expect { described_class.parse_headers("X: a\nb", lf) }.to output(%r{CR/LF}).to_stderr
        expect { described_class.parse_headers("X: a\rb", cr) }.to output(%r{CR/LF}).to_stderr
        expect(lf[:headers]).to be_empty
        expect(cr[:headers]).to be_empty
      end
    end

    describe 'wiring --headers through the full parser' do
      it 'routes each --headers occurrence into the accumulated header map' do
        expect(parse(['--headers=X-A: 1', '--headers=X-B: 2'])[:headers]).to eq('X-A' => '1', 'X-B' => '2')
      end
    end
  end

  describe HttpLoader::CliArgs::HarnessParser do
    # Wire HarnessParser into a parser; unlike the client it tolerates (and ignores) client-only flags.
    def parse(argv)
      options = {}
      OptionParser.new { |opts| described_class.parse(opts, options) }.parse!(argv)
      options
    end

    it 'documents every structural flag with its description in the generated help text' do
      help = OptionParser.new { |opts| described_class.parse(opts, {}) }.to_s
      [
        'Total connection count', 'Use HTTPS natively', 'Comma-separated target URLs',
        'Write the JSON run report to FILE', 'Stop after S seconds'
      ].each { |description| expect(help).to include(description) }
    end

    it 'parses the harness structural flags' do
      opts = parse(['--connections_count=100', '--https', '--url=http://a, http://b'])
      expect(opts[:connections]).to eq(100)
      expect(opts[:use_https]).to be(true)
      expect(opts[:target_urls]).to eq(['http://a', 'http://b'])
    end

    it 'parses the harness-only extras' do
      opts = parse(['--export_json=out.json', '--target_duration=30.0'])
      expect(opts[:export_json]).to eq('out.json')
      expect(opts[:target_duration]).to eq(30.0)
    end

    it 'tolerates every client-only flag without recording or rejecting it' do
      argv = %w[
        --verbose --ping --ping_period=1 --http_loader_timeout=1 --connections_per_second=1
        --max_concurrent_connections=1 --reopen_closed_connections --reopen_interval=1 --read_timeout=1
        --user_agent=A --jitter=1 --track_status_codes --ramp_up=1 --bind_ips=1.1.1.1 --proxy_pool=http://p
        --qps_per_connection=1 --headers=A:1 --slowloris_delay=1
      ]
      opts = parse(argv + ['--connections_count=5'])
      expect(opts[:connections]).to eq(5)
      expect(opts.keys).to contain_exactly(:connections)
    end

    it 'lists every client-only flag the harness must tolerate' do
      expect(described_class::IGNORED_CLIENT_FLAGS).to include('--verbose', '--headers=LIST', '--slowloris_delay=S')
    end
  end
end
