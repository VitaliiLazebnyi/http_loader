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
    it 'starts with no server or client pid recorded' do
      expect([manager.server_pid, manager.client_pid]).to(eq([nil, nil]))
    end

    it 'resolves the log directory to the absolute project logs path' do
      # spec/http_loader/harness -> repo root
      expect(manager.instance_variable_get(:@log_dir)).to(eq(File.expand_path('../../../logs', __dir__)))
    end
  end

  describe '#missing_process?' do
    it 'is false when neither tracked pid is set' do
      expect(manager.missing_process?).to(be(false))
    end

    it 'is false while both tracked processes are alive' do
      pids.merge!(server: 10, client: 20)
      allow(manager).to(receive(:dead?).and_return(false))
      expect(manager.missing_process?).to(be(false))
    end

    it 'is true when the client pid is set and dead' do
      pids[:client] = 20
      allow(manager).to(receive(:dead?).with(20).and_return(true))
      expect(manager.missing_process?).to(be(true))
    end

    it 'is true when the server pid is set and dead even though the client pid is unset' do
      pids[:server] = 10
      allow(manager).to(receive(:dead?).with(10).and_return(true))
      expect(manager.missing_process?).to(be(true))
    end

    it 'does not probe a nil client pid (guards dead? behind the presence check)' do
      allow(manager).to(receive(:dead?))
      manager.missing_process?
      expect(manager).not_to(have_received(:dead?))
    end
  end

  describe '#dead?' do
    it 'is false when getpgid resolves the process group' do
      allow(Process).to(receive(:getpgid).with(123).and_return(456))
      expect(manager.__send__(:dead?, 123)).to(be(false))
    end

    it 'is true when getpgid raises ESRCH (no such process)' do
      allow(Process).to(receive(:getpgid).with(123).and_raise(Errno::ESRCH))
      expect(manager.__send__(:dead?, 123)).to(be(true))
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
      allow(manager).to(receive(:terminate))
      manager.cleanup
      expect(manager).to(have_received(:terminate).with(10))
      expect(manager).to(have_received(:terminate).with(20))
    end
  end

  describe '#terminate' do
    before { allow(manager).to(receive(:signal_quietly)) }

    it 'does nothing for a nil pid' do
      manager.__send__(:terminate, nil)
      expect(manager).not_to(have_received(:signal_quietly))
    end

    context 'when the child is reaped within the 3s grace period' do
      before do
        allow(manager).to(receive(:reaped?).with(556, deadline: 3.0).and_return(true))
        manager.__send__(:terminate, 556)
      end

      it('sends SIGINT') { expect(manager).to(have_received(:signal_quietly).with('INT', 556)) }
      it('does not send SIGKILL') { expect(manager).not_to(have_received(:signal_quietly).with('KILL', 556)) }
    end

    context 'when SIGINT does not reap the child' do
      before do
        allow(manager).to(receive(:reaped?).with(556, deadline: 3.0).and_return(false))
        allow(manager).to(receive(:reaped?).with(556, deadline: 2.0).and_return(true))
        manager.__send__(:terminate, 556)
      end

      it('escalates to SIGKILL') { expect(manager).to(have_received(:signal_quietly).with('KILL', 556)) }
      it('reaps with a 2s deadline') { expect(manager).to(have_received(:reaped?).with(556, deadline: 2.0)) }
    end
  end

  describe '#reaped?' do
    it 'returns true as soon as waitpid(WNOHANG) reaps the child' do
      allow(Process).to(receive(:waitpid).with(1, Process::WNOHANG).and_return(1))
      expect(manager.__send__(:reaped?, 1, deadline: 1.0)).to(be(true))
    end

    it 'returns true when the child is already gone (ECHILD)' do
      allow(Process).to(receive(:waitpid).and_raise(Errno::ECHILD))
      expect(manager.__send__(:reaped?, 1, deadline: 1.0)).to(be(true))
    end

    it 'returns true when the pid is unknown (ESRCH)' do
      allow(Process).to(receive(:waitpid).and_raise(Errno::ESRCH))
      expect(manager.__send__(:reaped?, 1, deadline: 1.0)).to(be(true))
    end

    context 'when the child is never reaped' do
      before do
        allow(manager).to(receive(:sleep))
        allow(Process).to(receive(:waitpid).and_return(nil))
        allow(Time).to(receive(:now).and_return(Time.at(0), Time.at(0.5), Time.at(2)))
      end

      it 'gives up (false) once the deadline passes' do
        expect(manager.__send__(:reaped?, 1, deadline: 1.0)).to(be(false))
      end

      it 'polls with a 0.05s backoff' do
        manager.__send__(:reaped?, 1, deadline: 1.0)
        expect(manager).to(have_received(:sleep).with(0.05))
      end
    end
  end

  describe '#signal_quietly' do
    it 'sends the named signal to the pid' do
      allow(Process).to(receive(:kill))
      manager.__send__(:signal_quietly, 'TERM', 42)
      expect(Process).to(have_received(:kill).with('TERM', 42))
    end

    it 'swallows a raised error rather than propagating it' do
      allow(Process).to(receive(:kill).and_raise(Errno::ESRCH))
      expect { manager.__send__(:signal_quietly, 'INT', 42) }
        .not_to(raise_error)
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
      allow(manager).to(receive_messages(port_open?: false, dead?: false, sleep: nil))
      allow(Time).to(receive(:now).and_return(Time.at(0), Time.at(0), Time.at(100)))
    end

    context 'when the HTTP port is open' do
      before do
        allow(manager).to(receive(:port_open?).and_return(true))
        manager.__send__(:wait_for_server)
      end

      it('probes port 8080') { expect(manager).to(have_received(:port_open?).with(8080)) }
      it('returns before any backoff sleep') { expect(manager).not_to(have_received(:sleep)) }
    end

    context 'when HTTPS is enabled' do
      let(:overrides) { { use_https: true } }

      it 'probes port 8443' do
        allow(manager).to(receive(:port_open?).and_return(true))
        manager.__send__(:wait_for_server)
        expect(manager).to(have_received(:port_open?).with(8443))
      end
    end

    context 'when the server dies before binding' do
      before do
        pids[:server] = 111
        allow(manager).to(receive(:dead?).and_return(true))
      end

      it 'warns' do
        expect { manager.__send__(:wait_for_server) }
          .to(output(/did not become ready/).to_stderr)
      end

      it 'probes the server pid and breaks without a further backoff sleep', :aggregate_failures do
        expect { manager.__send__(:wait_for_server) }
          .to(output.to_stderr)
        expect(manager).to(have_received(:dead?).with(111))
        expect(manager).not_to(have_received(:sleep))
      end
    end

    it 'does not probe liveness while no server pid is recorded yet', :aggregate_failures do
      # @pids has no :server, so the poll runs to the deadline and reports the timeout.
      expect { manager.__send__(:wait_for_server) }
        .to(output(/did not become ready/).to_stderr)
      expect(manager).not_to(have_received(:dead?))
    end

    context 'when the deadline elapses' do
      before { pids[:server] = 111 }

      it 'warns, naming the port and the timeout' do
        expect { manager.__send__(:wait_for_server) }
          .to(output("[Harness] Warning: server did not become ready on port 8080 within 15.0s.\n").to_stderr)
      end

      it 'backs off 0.1s per poll', :aggregate_failures do
        expect { manager.__send__(:wait_for_server) }
          .to(output.to_stderr)
        expect(manager).to(have_received(:sleep).with(0.1))
      end
    end
  end

  describe '#port_open?' do
    it 'opens and closes a TCP connection to the IPv4 loopback address and returns true', :aggregate_failures do
      socket = instance_double(TCPSocket, close: nil)
      loopback = satisfy { |host| IPAddr.new(host).loopback? }
      allow(TCPSocket).to(receive(:new).with(loopback, 8080).and_return(socket))
      expect(manager.__send__(:port_open?, 8080)).to(be(true))
      expect(socket).to(have_received(:close))
    end

    it 'returns false when the connection is refused' do
      allow(TCPSocket).to(receive(:new).and_raise(Errno::ECONNREFUSED))
      expect(manager.__send__(:port_open?, 8080)).to(be(false))
    end
  end
end
