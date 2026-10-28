# typed: false
# frozen_string_literal: true

require 'spec_helper'
require 'http_loader/client/target_manager'
require 'http_loader/client/config'

RSpec.describe HttpLoader::Client::TargetManager do
  def config(**overrides)
    defaults = {
      connections: 1, target_urls: ['http://local'], use_https: false,
      verbose: false, ping: false, ping_period: 0, http_loader_timeout: 0.0,
      connections_per_second: 0, max_concurrent_connections: 1,
      reopen_closed_connections: false, reopen_interval: 0.0,
      read_timeout: 5.0, user_agent: 'A', jitter: 0.0,
      track_status_codes: false, ramp_up: 0.0, bind_ips: [],
      proxy_pool: [], qps_per_connection: 0, headers: {}, slowloris_delay: 0.0
    }
    HttpLoader::Client::Config.new(**defaults, **overrides)
  end

  let(:manager) { described_class.new(config) }

  before { allow(Addrinfo).to receive(:getaddrinfo).and_return([]) }

  describe '#protocol_label' do
    it 'labels a single external URL with its upcased scheme' do
      expect(described_class.new(config(target_urls: ['http://local'])).protocol_label).to eq('EXTERNAL HTTP')
    end

    it 'upcases an https scheme for a single external URL' do
      expect(described_class.new(config(target_urls: ['https://secure'])).protocol_label).to eq('EXTERNAL HTTPS')
    end

    it 'rejects a hostless URL with a clear configuration error naming the value' do
      expect { described_class.new(config(target_urls: ['foo.com'])) }
        .to raise_error(ArgumentError, 'Invalid --url (missing host): "foo.com"')
    end

    it 'labels a scheme-less but hosted URL with a blank scheme' do
      expect(described_class.new(config(target_urls: ['//example.com'])).protocol_label).to eq('EXTERNAL ')
    end

    it 'labels exactly two targets as MULTIPLE TARGETS (2)' do
      expect(described_class.new(config(target_urls: ['http://a', 'http://b'])).protocol_label)
        .to eq('MULTIPLE TARGETS (2)')
    end

    it 'labels three targets as MULTIPLE TARGETS (3)' do
      expect(described_class.new(config(target_urls: ['http://a', 'http://b', 'http://c'])).protocol_label)
        .to eq('MULTIPLE TARGETS (3)')
    end

    it 'maps HTTPS when no target_urls are provided and use_https is set' do
      expect(described_class.new(config(target_urls: [], use_https: true)).protocol_label).to eq('HTTPS')
    end

    it 'maps HTTP when no target_urls are provided and use_https is unset' do
      expect(described_class.new(config(target_urls: [], use_https: false)).protocol_label).to eq('HTTP')
    end
  end

  describe '#contexts' do
    it 'leaves ipaddr nil when Addrinfo yields nothing' do
      expect(manager.contexts.first[:http_args][:ipaddr]).to be_nil
    end

    it 'resolves the first IPv4 address when Addrinfo returns results' do
      allow(Addrinfo).to receive(:getaddrinfo).and_return([Addrinfo.tcp('1.2.3.4', 80)])
      expect(manager.contexts.first[:http_args][:ipaddr]).to eq('1.2.3.4')
    end

    it 'prefers the IPv4 entry over an earlier IPv6 one' do
      allow(Addrinfo).to receive(:getaddrinfo).and_return([Addrinfo.tcp('::1', 80), Addrinfo.tcp('9.9.9.9', 80)])
      expect(manager.contexts.first[:http_args][:ipaddr]).to eq('9.9.9.9')
    end

    it 'falls back to the first entry when none is IPv4' do
      allow(Addrinfo).to receive(:getaddrinfo).and_return([Addrinfo.tcp('::1', 80)])
      expect(manager.contexts.first[:http_args][:ipaddr]).to eq('::1')
    end

    it 'treats a SocketError during resolution as an unknown address (nil)' do
      allow(Addrinfo).to receive(:getaddrinfo).and_raise(SocketError)
      expect(manager.contexts.first[:http_args][:ipaddr]).to be_nil
    end

    it 'passes a positive read_timeout through to the HTTP args' do
      expect(described_class.new(config(read_timeout: 5.0)).contexts.first[:http_args][:read_timeout]).to eq(5.0)
    end

    it 'maps a zero read_timeout to nil (unlimited)' do
      expect(described_class.new(config(read_timeout: 0.0)).contexts.first[:http_args][:read_timeout]).to be_nil
    end

    it 'passes a sub-second read_timeout through (the boundary is strictly > 0)' do
      expect(described_class.new(config(read_timeout: 0.5)).contexts.first[:http_args][:read_timeout]).to eq(0.5)
    end

    it 'adds SSL options (verify disabled) for an HTTPS target' do
      args = described_class.new(config(target_urls: ['https://secure'])).contexts.first[:http_args]
      expect(args[:use_ssl]).to be(true)
      expect(args[:verify_mode]).to eq(OpenSSL::SSL::VERIFY_NONE)
    end

    it 'leaves a plain HTTP context without SSL options' do
      args = manager.contexts.first[:http_args]
      expect(args).not_to have_key(:use_ssl)
      expect(args).not_to have_key(:verify_mode)
    end

    it 'defaults to http://localhost:8080 when no target_urls are given' do
      expect(described_class.new(config(target_urls: [], use_https: false)).contexts.first[:uri].to_s)
        .to eq('http://localhost:8080')
    end

    it 'defaults to https://localhost:8443 when no target_urls are given and use_https is set' do
      expect(described_class.new(config(target_urls: [], use_https: true)).contexts.first[:uri].to_s)
        .to eq('https://localhost:8443')
    end
  end

  describe '#context_for' do
    let(:multi) { described_class.new(config(target_urls: ['http://a', 'http://b'])) }

    it 'wraps the index around the context count' do
      expect(multi.context_for(0)[:uri].host).to eq('a')
      expect(multi.context_for(1)[:uri].host).to eq('b')
      expect(multi.context_for(2)[:uri].host).to eq('a')
      expect(multi.context_for(3)[:uri].host).to eq('b')
    end
  end

  describe '#http_opts_for' do
    it 'returns opts unchanged when neither bind_ips nor proxy_pool are set' do
      expect(manager.http_opts_for(0, {})).to eq({})
    end

    it 'does not mutate the caller-supplied args hash' do
      original = { read_timeout: 1.0 }
      described_class.new(config(proxy_pool: ['http://proxy.com'])).http_opts_for(0, original)
      expect(original).to eq(read_timeout: 1.0)
    end

    it 'round-robins bind_ips by connection index' do
      mgr = described_class.new(config(bind_ips: ['1.1.1.1', '2.2.2.2']))
      expect(mgr.http_opts_for(0, {})[:local_host]).to eq('1.1.1.1')
      expect(mgr.http_opts_for(1, {})[:local_host]).to eq('2.2.2.2')
      expect(mgr.http_opts_for(2, {})[:local_host]).to eq('1.1.1.1')
    end

    it 'maps a plain proxy (default port 80, no credentials)' do
      opts = described_class.new(config(proxy_pool: ['http://proxy.com'])).http_opts_for(0, {})
      expect(opts[:proxy_address]).to eq('proxy.com')
      expect(opts[:proxy_port]).to eq(80)
      expect(opts).not_to have_key(:proxy_user)
      expect(opts).not_to have_key(:proxy_pass)
    end

    it 'parses an explicit proxy port' do
      opts = described_class.new(config(proxy_pool: ['http://proxy.com:8080'])).http_opts_for(0, {})
      expect(opts[:proxy_port]).to eq(8080)
    end

    it 'round-robins the proxy pool by connection index' do
      mgr = described_class.new(config(proxy_pool: ['http://a.com', 'http://b.com']))
      expect(mgr.http_opts_for(0, {})[:proxy_address]).to eq('a.com')
      expect(mgr.http_opts_for(1, {})[:proxy_address]).to eq('b.com')
      expect(mgr.http_opts_for(2, {})[:proxy_address]).to eq('a.com')
    end

    it 'maps credentials and a bound IP together' do
      mgr = described_class.new(config(proxy_pool: ['http://u:p@proxy.com'], bind_ips: ['1.1.1.1']))
      opts = mgr.http_opts_for(0, {})
      expect(opts[:proxy_user]).to eq('u')
      expect(opts[:proxy_pass]).to eq('p')
      expect(opts[:local_host]).to eq('1.1.1.1')
    end

    it 'maps a user with no password' do
      opts = described_class.new(config(proxy_pool: ['http://u@proxy.com'])).http_opts_for(0, {})
      expect(opts[:proxy_user]).to eq('u')
      expect(opts).not_to have_key(:proxy_pass)
    end

    it 'raises a clear error naming the unparseable proxy entry' do
      mgr = described_class.new(config(proxy_pool: ['@']))
      expect { mgr.http_opts_for(0, {}) }
        .to raise_error(ArgumentError, 'Invalid --proxy_pool entry: "@"')
    end
  end
end
