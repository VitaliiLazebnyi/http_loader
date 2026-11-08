# typed: true
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'ipaddr'
require 'spec_helper'

RSpec.describe(HttpLoader::Harness::ProcessManager) do
  let(:overrides)   { {} }
  let(:client_args) { [] }
  let(:manager) do
    config = ConfigFactory.harness({ target_urls: ['http://local'], connections: 1 }.merge(overrides), client_args)
    HttpLoader::Harness::ProcessManager.new(config)
  end
  # The pid map a spawn fills in; examples record pids in it directly.
  let(:pids) { manager.instance_variable_get(:@pids) }

  describe '#initialize' do
    it 'keeps the config' do
      expect(manager.instance_variable_get(:@config).connections).to(eq(1))
    end

    it 'starts with no server or client pid recorded' do
      expect([manager.server_pid, manager.client_pid]).to(eq([nil, nil]))
    end

    it 'resolves the log directory to the absolute project logs path' do
      # spec/http_loader/harness -> repo root
      expect(manager.instance_variable_get(:@log_dir)).to(eq(File.expand_path('../../../logs', __dir__)))
    end
  end

  describe '#missing_process?' do
    before { allow(HttpLoader::Harness::ProcessControl).to(receive(:dead?).and_return(false)) }

    it 'is false when neither tracked pid is set' do
      expect(manager.missing_process?).to(be(false))
    end

    it 'is false while both tracked processes are alive' do
      pids.merge!(server: 10, client: 20)
      expect(manager.missing_process?).to(be(false))
    end

    it 'is true when the client pid is set and dead' do
      pids[:client] = 20
      allow(HttpLoader::Harness::ProcessControl).to(receive(:dead?).with(20).and_return(true))
      expect(manager.missing_process?).to(be(true))
    end

    it 'is true when the server pid is set and dead even though the client pid is unset' do
      pids[:server] = 10
      allow(HttpLoader::Harness::ProcessControl).to(receive(:dead?).with(10).and_return(true))
      expect(manager.missing_process?).to(be(true))
    end

    it 'does not probe a nil pid (guards dead? behind the presence check)' do
      manager.missing_process?
      expect(HttpLoader::Harness::ProcessControl).not_to(have_received(:dead?))
    end
  end

  describe '.dead?' do
    it 'is false for a nil (not started) pid' do
      expect(HttpLoader::Harness::ProcessManager.dead?(nil)).to(be(false))
    end

    it 'asks ProcessControl about a started pid', :aggregate_failures do
      allow(HttpLoader::Harness::ProcessControl).to(receive(:dead?).with(7).and_return(true))
      expect(HttpLoader::Harness::ProcessManager.dead?(7)).to(be(true))
      expect(HttpLoader::Harness::ProcessControl).to(have_received(:dead?).with(7))
    end
  end

  describe '#spawn_processes' do
    let(:calls) { [] }

    before do
      allow(FileUtils).to(receive(:mkdir_p))
      allow(manager).to(receive(:spawn_server) { calls << :server })
      allow(manager).to(receive(:spawn_client) { calls << :client })
      manager.spawn_processes
    end

    it 'creates the log directory before spawning' do
      expect(FileUtils).to(have_received(:mkdir_p).with(manager.instance_variable_get(:@log_dir)))
    end

    it('spawns only the client when target URLs are configured') { expect(calls).to(eq([:client])) }

    context 'when no target URLs are configured' do
      let(:overrides) { { target_urls: [] } }

      it('spawns the server before the client') { expect(calls).to(eq(%i[server client])) }
    end
  end

  describe '#cleanup' do
    it 'terminates both the server and client pids', :aggregate_failures do
      pids.merge!(server: 10, client: 20)
      allow(HttpLoader::Harness::ProcessControl).to(receive(:terminate))
      manager.cleanup
      expect(HttpLoader::Harness::ProcessControl).to(have_received(:terminate).with(10).ordered)
      expect(HttpLoader::Harness::ProcessControl).to(have_received(:terminate).with(20).ordered)
    end
  end

  describe '#spawn_server' do
    before do
      allow(manager).to(receive_messages(spawn_child: 998, wait_for_server: nil, puts: nil))
      manager.__send__(:spawn_server)
    end

    it 'spawns the plain server subcommand into server.log/server.err' do
      expect(manager).to(have_received(:spawn_child).with(['server'], 'server.log', 'server.err'))
    end

    it('records the server pid') { expect(manager.server_pid).to(eq(998)) }
    it('waits for readiness') { expect(manager).to(have_received(:wait_for_server)) }

    it 'announces the server pid' do
      expect(manager).to(have_received(:puts).with('[Harness] Started server with PID 998'))
    end

    context 'when HTTPS is enabled' do
      let(:overrides) { { use_https: true } }

      it 'appends --https to the server args' do
        expect(manager).to(have_received(:spawn_child).with(%w[server --https], 'server.log', 'server.err'))
      end
    end
  end

  describe '#spawn_client' do
    before do
      allow(manager).to(receive_messages(spawn_child: 999, puts: nil))
      manager.__send__(:spawn_client)
    end

    it 'defaults the client args to the configured connection count when none are given' do
      expect(manager).to(
        have_received(:spawn_child)
                .with(['client', '--connections_count=1'], 'client.stdout.log', 'client.stderr.log')
      )
    end

    it 'announces the client pid' do
      expect(manager).to(have_received(:puts).with('[Harness] Started client with PID 999'))
    end

    context 'with explicit client args' do
      let(:client_args) { ['--verbose'] }

      it 'forwards them verbatim instead of the default' do
        expect(manager).to(
          have_received(:spawn_child)
                    .with(['client', '--verbose'], 'client.stdout.log', 'client.stderr.log')
        )
      end
    end
  end

  describe '#spawn_child' do
    before { allow(Process).to(receive(:spawn).and_return(777)) }

    it 'returns the spawned pid' do
      expect(manager.__send__(:spawn_child, %w[server], 'o.log', 'e.log')).to(eq(777))
    end

    it 'spawns the resolved interpreter and absolute bin path with the args, redirecting both streams' do
      manager.__send__(:spawn_child, %w[server --https], 'o.log', 'e.log')
      log_dir = manager.instance_variable_get(:@log_dir)
      expect(Process).to(
        have_received(:spawn).with(
          Shellwords.join(
            [
              RbConfig.ruby,
              HttpLoader::Harness::ProcessManager::BIN_PATH,
              'server',
              '--https'
            ]
          ),
          out: File.join(log_dir, 'o.log'),
          err: File.join(log_dir, 'e.log')
        )
      )
    end
  end

  describe '#wait_for_server' do
    before do
      allow(HttpLoader::Harness::ProcessManager).to(receive_messages(port_open?: false, dead?: false))
      allow(manager).to(receive(:sleep))
    end

    context 'when the HTTP port is open' do
      before do
        allow(HttpLoader::Harness::ProcessManager).to(receive(:port_open?).and_return(true))
        manager.__send__(:wait_for_server)
      end

      it('probes port 8080') { expect(HttpLoader::Harness::ProcessManager).to(have_received(:port_open?).with(8080)) }
      it('returns before any backoff sleep') { expect(manager).not_to(have_received(:sleep)) }
    end

    context 'when HTTPS is enabled' do
      let(:overrides) { { use_https: true } }

      it 'probes port 8443' do
        allow(HttpLoader::Harness::ProcessManager).to(receive(:port_open?).and_return(true))
        manager.__send__(:wait_for_server)
        expect(HttpLoader::Harness::ProcessManager).to(have_received(:port_open?).with(8443))
      end
    end

    context 'when the server dies before binding' do
      before do
        pids[:server] = 111
        allow(HttpLoader::Harness::ProcessManager).to(receive(:dead?).and_return(true))
      end

      it 'warns' do
        expect { manager.__send__(:wait_for_server) }
          .to(output(/did not become ready/).to_stderr)
      end

      it 'probes the server pid and stops without a backoff sleep', :aggregate_failures do
        expect { manager.__send__(:wait_for_server) }
          .to(output.to_stderr)
        expect(HttpLoader::Harness::ProcessManager).to(have_received(:dead?).with(111).once)
        expect(manager).not_to(have_received(:sleep))
      end
    end

    context 'when the port never opens' do
      before { pids[:server] = 111 }

      it 'warns, naming the port and the timeout' do
        expect { manager.__send__(:wait_for_server) }
          .to(output("[Harness] Warning: server did not become ready on port 8080 within 15.0s.\n").to_stderr)
      end

      it 'polls every 0.1s for 15s', :aggregate_failures do
        expect { manager.__send__(:wait_for_server) }
          .to(output.to_stderr)
        expect(HttpLoader::Harness::ProcessManager).to(have_received(:port_open?).exactly(150).times)
        expect(manager).to(have_received(:sleep).with(0.1).exactly(150).times)
      end
    end
  end

  describe '.port_open?' do
    it 'opens and closes a TCP connection to the IPv4 loopback address and returns true', :aggregate_failures do
      socket = instance_double(TCPSocket, close: nil)
      loopback = satisfy { |host| IPAddr.new(host).loopback? }
      allow(TCPSocket).to(receive(:new).with(loopback, 8080).and_return(socket))
      expect(HttpLoader::Harness::ProcessManager.port_open?(8080)).to(be(true))
      expect(socket).to(have_received(:close))
    end

    it 'returns false when the connection is refused' do
      allow(TCPSocket).to(receive(:new).and_raise(Errno::ECONNREFUSED))
      expect(HttpLoader::Harness::ProcessManager.port_open?(8080)).to(be(false))
    end
  end
end
