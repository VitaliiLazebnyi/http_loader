# typed: true
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'spec_helper'

RSpec.describe(HttpLoader::Client::TargetManager) do
  subject(:manager) do
    HttpLoader::Client::TargetManager.new(
      ConfigFactory.client({ target_urls: ['http://local'], read_timeout: 5.0 }.merge(overrides))
    )
  end

  let(:overrides)  { {}                                  }
  let(:first_args) { manager.contexts.fetch(0).http_args }

  before { allow(Addrinfo).to(receive(:getaddrinfo).and_return([])) }

  describe '#protocol_label' do
    it 'labels a single external URL with its upcased scheme' do
      expect(manager.protocol_label).to(eq('EXTERNAL HTTP'))
    end

    context 'with a single https URL' do
      let(:overrides) { { target_urls: ['https://secure'] } }

      it('upcases the scheme') { expect(manager.protocol_label).to(eq('EXTERNAL HTTPS')) }
    end

    context 'with a hostless URL' do
      let(:overrides) { { target_urls: ['foo.com'] } }

      it 'rejects it with a clear configuration error naming the value' do
        expect { manager }
          .to(raise_error(ArgumentError, 'Invalid --url (missing host): "foo.com"'))
      end
    end

    context 'with a scheme-less but hosted URL' do
      let(:overrides) { { target_urls: ['//example.com'] } }

      it('labels it with a blank scheme') { expect(manager.protocol_label).to(eq('EXTERNAL ')) }
    end

    context 'with exactly two targets' do
      let(:overrides) { { target_urls: ['http://a', 'http://b'] } }

      it('labels them as MULTIPLE TARGETS (2)') { expect(manager.protocol_label).to(eq('MULTIPLE TARGETS (2)')) }
    end

    context 'with three targets' do
      let(:overrides) { { target_urls: ['http://a', 'http://b', 'http://c'] } }

      it('labels them as MULTIPLE TARGETS (3)') { expect(manager.protocol_label).to(eq('MULTIPLE TARGETS (3)')) }
    end

    context 'without target URLs, with HTTPS' do
      let(:overrides) { { target_urls: [], use_https: true } }

      it('labels the local server as HTTPS') { expect(manager.protocol_label).to(eq('HTTPS')) }
    end

    context 'without target URLs, without HTTPS' do
      let(:overrides) { { target_urls: [], use_https: false } }

      it('labels the local server as HTTP') { expect(manager.protocol_label).to(eq('HTTP')) }
    end
  end

  describe '#contexts' do
    it 'leaves ipaddr nil when Addrinfo yields nothing' do
      expect(first_args.fetch(:ipaddr).nil?).to(be(true))
    end

    it 'resolves the first IPv4 address when Addrinfo returns results' do
      allow(Addrinfo).to(receive(:getaddrinfo).and_return([Addrinfo.tcp(TestAddresses.ip(4), 80)]))
      expect(first_args.fetch(:ipaddr)).to(eq(TestAddresses.ip(4)))
    end

    it 'prefers the IPv4 entry over an earlier IPv6 one' do
      allow(Addrinfo).to(
        receive(:getaddrinfo).and_return(
          [
            Addrinfo.tcp(TestAddresses.ipv6(1), 80),
            Addrinfo.tcp(TestAddresses.ip(9), 80)
          ]
        )
      )
      expect(first_args.fetch(:ipaddr)).to(eq(TestAddresses.ip(9)))
    end

    it 'falls back to the first entry when none is IPv4' do
      allow(Addrinfo).to(receive(:getaddrinfo).and_return([Addrinfo.tcp(TestAddresses.ipv6(1), 80)]))
      expect(first_args.fetch(:ipaddr)).to(eq(TestAddresses.ipv6(1)))
    end

    it 'treats a SocketError during resolution as an unknown address (nil)' do
      allow(Addrinfo).to(receive(:getaddrinfo).and_raise(SocketError))
      expect(first_args.fetch(:ipaddr).nil?).to(be(true))
    end

    it 'passes a positive read_timeout through to the HTTP args' do
      expect(first_args.fetch(:read_timeout)).to(eq(5.0))
    end

    it 'leaves a plain HTTP context without SSL options', :aggregate_failures do
      expect(first_args.key?(:use_ssl)).to(be(false))
      expect(first_args.key?(:verify_mode)).to(be(false))
    end

    context 'with a zero read_timeout' do
      let(:overrides) { { read_timeout: 0.0 } }

      it('maps it to nil (unlimited)') { expect(first_args.fetch(:read_timeout).nil?).to(be(true)) }
    end

    context 'with a sub-second read_timeout' do
      let(:overrides) { { read_timeout: 0.5 } }

      it('passes it through (the boundary is strictly > 0)') { expect(first_args.fetch(:read_timeout)).to(eq(0.5)) }
    end

    context 'with an HTTPS target' do
      let(:overrides) { { target_urls: ['https://secure'] } }

      it 'adds SSL options with verification disabled', :aggregate_failures do
        expect(first_args.fetch(:use_ssl)).to(be(true))
        expect(first_args.fetch(:verify_mode)).to(eq(OpenSSL::SSL::VERIFY_NONE))
      end
    end

    context 'without target URLs, without HTTPS' do
      let(:overrides) { { target_urls: [], use_https: false } }

      it 'targets http://localhost:8080' do
        expect(manager.contexts.fetch(0).uri.to_s).to(eq('http://localhost:8080'))
      end
    end

    context 'without target URLs, with HTTPS' do
      let(:overrides) { { target_urls: [], use_https: true } }

      it 'targets https://localhost:8443' do
        expect(manager.contexts.fetch(0).uri.to_s).to(eq('https://localhost:8443'))
      end
    end
  end

  describe '#context_for' do
    let(:overrides) { { target_urls: ['http://a', 'http://b'] } }

    it 'wraps the index around the context count' do
      expect((0..3).map { |index| manager.context_for(index).uri.host }).to(eq(%w[a b a b]))
    end
  end

  describe '#http_opts_for' do
    it 'returns opts unchanged when neither bind_ips nor proxy_pool are set' do
      expect(manager.http_opts_for(0, {})).to(eq({}))
    end

    context 'with bind IPs' do
      let(:overrides) { { bind_ips: [TestAddresses.ip(1), TestAddresses.ip(2)] } }

      it 'round-robins them by connection index' do
        expect((0..2).map { |index| manager.http_opts_for(index, {}).fetch(:local_host) })
          .to(eq([TestAddresses.ip(1), TestAddresses.ip(2), TestAddresses.ip(1)]))
      end
    end

    context 'with a plain proxy' do
      let(:overrides) { { proxy_pool: ['http://proxy.com'] } }

      it 'maps it with the default port 80 and no credentials' do
        expect(manager.http_opts_for(0, {})).to(eq(proxy_address: 'proxy.com', proxy_port: 80))
      end

      it 'does not mutate the caller-supplied args hash' do
        original = { read_timeout: 1.0 }
        manager.http_opts_for(0, original)
        expect(original).to(eq(read_timeout: 1.0))
      end
    end

    context 'with an explicit proxy port' do
      let(:overrides) { { proxy_pool: ['http://proxy.com:8080'] } }

      it('parses the port') { expect(manager.http_opts_for(0, {}).fetch(:proxy_port)).to(eq(8080)) }
    end

    context 'with a proxy pool' do
      let(:overrides) { { proxy_pool: ['http://a.com', 'http://b.com'] } }

      it 'round-robins it by connection index' do
        expect((0..2).map { |index| manager.http_opts_for(index, {}).fetch(:proxy_address) })
          .to(eq(%w[a.com b.com a.com]))
      end
    end

    context 'with proxy credentials and a bound IP' do
      let(:overrides) { { proxy_pool: ['http://u:p@proxy.com'], bind_ips: [TestAddresses.ip(1)] } }

      it 'maps both together' do
        expect(manager.http_opts_for(0, {}).slice(:proxy_user, :proxy_pass, :local_host))
          .to(eq(proxy_user: 'u', proxy_pass: 'p', local_host: TestAddresses.ip(1)))
      end
    end

    context 'with a proxy user but no password' do
      let(:overrides) { { proxy_pool: ['http://u@proxy.com'] } }

      it 'maps the user only' do
        expect(manager.http_opts_for(0, {})).to(eq(proxy_address: 'proxy.com', proxy_port: 80, proxy_user: 'u'))
      end
    end

    context 'with an unparseable proxy entry' do
      let(:overrides) { { proxy_pool: ['@'] } }

      it 'raises a clear error naming it' do
        expect { manager.http_opts_for(0, {}) }
          .to(raise_error(ArgumentError, 'Invalid --proxy_pool entry: "@"'))
      end
    end
  end
end
