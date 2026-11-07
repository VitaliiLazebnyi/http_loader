# typed: true
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'spec_helper'

RSpec.describe(HttpLoader::CLI) do
  let(:client)  { instance_double(HttpLoader::Client, start: nil)          }
  let(:harness) { instance_double(HttpLoader::Harness, start: nil)         }
  let(:server)  { instance_double(HttpLoader::Server, start: nil)          }
  let(:usage)   { "Usage: http_loader <client|server|harness> [options]\n" }
  let(:configuration_errors) do
    [
      ArgumentError.new('bad value'),
      OptionParser::InvalidOption.new('--bad'),
      URI::InvalidURIError.new('bad uri'),
      TypeError.new('wrong type')
    ]
  end

  before do
    allow(HttpLoader::Client).to(receive(:new).and_return(client))
    allow(HttpLoader::Harness).to(receive(:new).and_return(harness))
    allow(HttpLoader::Server).to(receive(:new).and_return(server))
  end

  describe '.run without a known subcommand' do
    it 'prints the usage and exits 1 when no subcommand is given', :aggregate_failures do
      expect { expect(HttpLoader::CLI.run([])).to(eq(1)) }
        .to(output(usage).to_stderr)
    end

    it 'prints the usage and exits 1 for an unknown subcommand', :aggregate_failures do
      expect { expect(HttpLoader::CLI.run(['bogus'])).to(eq(1)) }
        .to(output(usage).to_stderr)
    end
  end

  describe '.run client' do
    it 'starts the client with the parsed configuration and exits 0', :aggregate_failures do
      expected = ConfigFactory.client(connections: 3, target_urls: ['http://a']).serialize
      expect(HttpLoader::CLI.run(['client', '--connections_count=3', '--url=http://a'])).to(eq(0))
      expect(HttpLoader::Client).to(have_received(:new).with(have_attributes(serialize: expected)))
      expect(client).to(have_received(:start))
    end

    it 'leaves the caller-supplied argv untouched' do
      argv = ['client', '--verbose']
      HttpLoader::CLI.run(argv)
      expect(argv).to(eq(['client', '--verbose']))
    end

    it 'runs the same arguments again on a second run' do
      cli = HttpLoader::CLI.new(['client', '--connections_count=2'])
      cli.run
      expect(cli.run).to(eq(0))
    end

    it 'names the subcommand in its usage banner', :aggregate_failures do
      help_run = -> { HttpLoader::CLI.run(['client', '--help']) }
      prints_banner = output(/\AUsage: http_loader client \[options\]\n/).to_stdout
      expect { expect(&help_run).to(raise_error(SystemExit)) }
        .to(prints_banner)
    end

    it 'reports each configuration error and exits 1', :aggregate_failures do
      configuration_errors.each do |error|
        allow(HttpLoader::Client).to(receive(:new).and_raise(error))
        expect { expect(HttpLoader::CLI.run(['client'])).to(eq(1)) }
          .to(output("Configuration Error: #{error.message}\n").to_stderr)
      end
    end

    it 'does not rescue other errors' do
      allow(HttpLoader::Client).to(receive(:new).and_raise(IOError))
      expect { HttpLoader::CLI.run(['client']) }
        .to(raise_error(IOError))
    end
  end

  describe '.run server' do
    it 'serves plain HTTP on 8080 by default and exits 0', :aggregate_failures do
      expect(HttpLoader::CLI.run(['server'])).to(eq(0))
      expect(server).to(have_received(:start).with(use_https: false, port: 8080))
    end

    it 'serves HTTPS on 8443 with --https' do
      HttpLoader::CLI.run(['server', '--https'])
      expect(server).to(have_received(:start).with(use_https: true, port: 8443))
    end

    it 'names the subcommand in its usage banner and describes --https', :aggregate_failures do
      help = /\AUsage: http_loader server \[options\]\n.*--https +Serve over HTTPS with an ephemeral self-signed/m
      help_run = -> { HttpLoader::CLI.run(['server', '--help']) }
      expect { expect(&help_run).to(raise_error(SystemExit)) }
        .to(output(help).to_stdout)
    end

    it 'reports an unknown flag as a configuration error and exits 1 without serving', :aggregate_failures do
      expect { expect(HttpLoader::CLI.run(['server', '--bogus'])).to(eq(1)) }
        .to(output("Configuration Error: invalid option: --bogus\n").to_stderr)
      expect(server).not_to(have_received(:start))
    end

    it 'does not rescue an error raised while serving' do
      allow(server).to(receive(:start).and_raise(ArgumentError))
      expect { HttpLoader::CLI.run(['server']) }
        .to(raise_error(ArgumentError))
    end
  end

  describe '.run harness' do
    it 'starts the harness, forwarding its flags to the client, and exits 0', :aggregate_failures do
      expected = ConfigFactory.harness({ connections: 4 }, ['--connections_count=4', '--verbose']).serialize
      expect(HttpLoader::CLI.run(['harness', '--connections_count=4', '--verbose'])).to(eq(0))
      expect(HttpLoader::Harness).to(have_received(:new).with(have_attributes(serialize: expected)))
      expect(harness).to(have_received(:start))
    end

    it 'names the subcommand in its usage banner', :aggregate_failures do
      help_run = -> { HttpLoader::CLI.run(['harness', '--help']) }
      prints_banner = output(/\AUsage: http_loader harness \[options\]\n/).to_stdout
      expect { expect(&help_run).to(raise_error(SystemExit)) }
        .to(prints_banner)
    end

    it 'reports each configuration error and exits 1', :aggregate_failures do
      configuration_errors.each do |error|
        allow(HttpLoader::Harness).to(receive(:new).and_raise(error))
        expect { expect(HttpLoader::CLI.run(['harness'])).to(eq(1)) }
          .to(output("Configuration Error: #{error.message}\n").to_stderr)
      end
    end

    it 'does not rescue other errors' do
      allow(HttpLoader::Harness).to(receive(:new).and_raise(IOError))
      expect { HttpLoader::CLI.run(['harness']) }
        .to(raise_error(IOError))
    end
  end
end
