# typed: false
# frozen_string_literal: true

require 'spec_helper'
require 'http_loader/harness/process_manager'
require 'http_loader/harness/config'

RSpec.describe HttpLoader::Harness::ProcessManager do
  let(:config) do
    HttpLoader::Harness::Config.new(
      target_urls: ['http://local'], connections: 1, use_https: false, client_args: [], export_json: nil
    )
  end
  let(:manager) { described_class.new(config) }
  let(:log_dir) { manager.instance_variable_get(:@log_dir) }

  # Record a spawned pid directly in the manager's pid map (the state a spawn would leave behind).
  def record_pid(role, pid)
    manager.instance_variable_get(:@pids)[role] = pid
  end

  describe '#initialize' do
    it 'retains the supplied config' do
      expect(manager.instance_variable_get(:@config)).to eq(config)
    end

    it 'starts with no server or client pid recorded' do
      expect(manager.server_pid).to be_nil
      expect(manager.client_pid).to be_nil
    end

    it 'resolves the log directory to the absolute project logs path' do
      project_root = File.expand_path('../../..', __dir__) # spec/http_loader/harness -> repo root
      expect(manager.instance_variable_get(:@log_dir)).to eq(File.join(project_root, 'logs'))
    end
  end

  describe '#missing_process?' do
    it 'is false when neither tracked pid is set' do
      expect(manager.missing_process?).to be(false)
    end

    it 'is false while both tracked processes are alive' do
      record_pid(:server, 10)
      record_pid(:client, 20)
      allow(manager).to receive(:dead?).and_return(false)
      expect(manager.missing_process?).to be(false)
    end

    it 'is true when the client pid is set and dead' do
      record_pid(:client, 20)
      allow(manager).to receive(:dead?).with(20).and_return(true)
      expect(manager.missing_process?).to be(true)
    end

    it 'is true when the server pid is set and dead even though the client pid is unset' do
      record_pid(:server, 10)
      allow(manager).to receive(:dead?).with(10).and_return(true)
      expect(manager.missing_process?).to be(true)
    end

    it 'does not probe a nil client pid (guards dead? behind the presence check)' do
      allow(manager).to receive(:dead?)
      manager.missing_process?
      expect(manager).not_to have_received(:dead?)
    end
  end

  describe '#dead?' do
    it 'is false when getpgid resolves the process group' do
      allow(Process).to receive(:getpgid).with(123).and_return(456)
      expect(manager.send(:dead?, 123)).to be(false)
    end

    it 'is true when getpgid raises ESRCH (no such process)' do
      allow(Process).to receive(:getpgid).with(123).and_raise(Errno::ESRCH)
      expect(manager.send(:dead?, 123)).to be(true)
    end
  end

  describe '#spawn_processes' do
    before { allow(FileUtils).to receive(:mkdir_p) }

    it 'creates the log directory before spawning' do
      allow(manager).to receive(:spawn_client)
      manager.spawn_processes
      expect(FileUtils).to have_received(:mkdir_p).with(log_dir)
    end

    it 'spawns only the client when target URLs are configured' do
      allow(manager).to receive_messages(spawn_server: nil, spawn_client: nil)
      manager.spawn_processes
      expect(manager).not_to have_received(:spawn_server)
      expect(manager).to have_received(:spawn_client)
    end

    context 'when no target URLs are configured' do
      let(:config) do
        HttpLoader::Harness::Config.new(
          target_urls: [], connections: 1, use_https: false, client_args: [], export_json: nil
        )
      end

      it 'spawns the server before the client' do
        calls = []
        allow(manager).to receive(:spawn_server) { calls << :server }
        allow(manager).to receive(:spawn_client) { calls << :client }
        manager.spawn_processes
        expect(calls).to eq(%i[server client])
      end
    end
  end

  describe '#cleanup' do
    it 'terminates both the server and client pids' do
      record_pid(:server, 10)
      record_pid(:client, 20)
      allow(manager).to receive(:terminate)
      manager.cleanup
      expect(manager).to have_received(:terminate).with(10)
      expect(manager).to have_received(:terminate).with(20)
    end
  end

  describe '#terminate' do
    it 'does nothing for a nil pid' do
      allow(Process).to receive(:kill)
      manager.send(:terminate, nil)
      expect(Process).not_to have_received(:kill)
    end

    it 'sends SIGINT and stops when the child is reaped within the 3s grace period' do
      allow(manager).to receive(:signal_quietly)
      allow(manager).to receive(:reaped?).with(556, deadline: 3.0).and_return(true)
      manager.send(:terminate, 556)
      expect(manager).to have_received(:signal_quietly).with('INT', 556)
      expect(manager).not_to have_received(:signal_quietly).with('KILL', 556)
    end

    it 'escalates to SIGKILL and reaps with a 2s deadline when SIGINT does not reap' do
      allow(manager).to receive(:signal_quietly)
      allow(manager).to receive(:reaped?).with(556, deadline: 3.0).and_return(false)
      allow(manager).to receive(:reaped?).with(556, deadline: 2.0).and_return(true)
      manager.send(:terminate, 556)
      expect(manager).to have_received(:signal_quietly).with('KILL', 556)
      expect(manager).to have_received(:reaped?).with(556, deadline: 2.0)
    end
  end

  describe '#reaped?' do
    it 'returns true as soon as waitpid(WNOHANG) reaps the child' do
      allow(Process).to receive(:waitpid).with(1, Process::WNOHANG).and_return(1)
      expect(manager.send(:reaped?, 1, deadline: 1.0)).to be(true)
    end

    it 'returns true when the child is already gone (ECHILD)' do
      allow(Process).to receive(:waitpid).and_raise(Errno::ECHILD)
      expect(manager.send(:reaped?, 1, deadline: 1.0)).to be(true)
    end

    it 'returns true when the pid is unknown (ESRCH)' do
      allow(Process).to receive(:waitpid).and_raise(Errno::ESRCH)
      expect(manager.send(:reaped?, 1, deadline: 1.0)).to be(true)
    end

    it 'polls with a 0.05s backoff and gives up (false) once the deadline passes' do
      allow(manager).to receive(:sleep)
      allow(Process).to receive(:waitpid).and_return(nil)
      t = Time.now
      allow(Time).to receive(:now).and_return(t, t + 0.5, t + 2)
      expect(manager.send(:reaped?, 1, deadline: 1.0)).to be(false)
      expect(manager).to have_received(:sleep).with(0.05)
    end
  end

  describe '#signal_quietly' do
    it 'sends the named signal to the pid' do
      allow(Process).to receive(:kill)
      manager.send(:signal_quietly, 'TERM', 42)
      expect(Process).to have_received(:kill).with('TERM', 42)
    end

    it 'swallows a raised error rather than propagating it' do
      allow(Process).to receive(:kill).and_raise(Errno::ESRCH)
      expect { manager.send(:signal_quietly, 'INT', 42) }.not_to raise_error
    end
  end

  describe '#spawn_server' do
    before do
      allow(manager).to receive_messages(spawn_child: 998, wait_for_server: nil)
      allow(manager).to receive(:puts)
    end

    it 'spawns the plain server subcommand into server.log/server.err and records the pid' do
      manager.send(:spawn_server)
      expect(manager).to have_received(:spawn_child).with(['server'], 'server.log', 'server.err')
      expect(manager.server_pid).to eq(998)
    end

    it 'appends --https to the server args when HTTPS is enabled' do
      cfg = HttpLoader::Harness::Config.new(
        target_urls: [], connections: 1, use_https: true, client_args: [], export_json: nil
      )
      mgr = described_class.new(cfg)
      allow(mgr).to receive_messages(spawn_child: 998, wait_for_server: nil, puts: nil)
      mgr.send(:spawn_server)
      expect(mgr).to have_received(:spawn_child).with(%w[server --https], 'server.log', 'server.err')
    end

    it 'announces the server pid and then waits for readiness' do
      manager.send(:spawn_server)
      expect(manager).to have_received(:puts).with('[Harness] Started server with PID 998')
      expect(manager).to have_received(:wait_for_server)
    end
  end

  describe '#spawn_client' do
    before { allow(manager).to receive_messages(spawn_child: 999, puts: nil) }

    it 'defaults the client args to the configured connection count when none are given' do
      manager.send(:spawn_client)
      expect(manager).to have_received(:spawn_child)
        .with(['client', '--connections_count=1'], 'client.stdout.log', 'client.stderr.log')
    end

    it 'forwards explicit client args verbatim instead of the default' do
      cfg = HttpLoader::Harness::Config.new(
        target_urls: ['http://local'], connections: 1, use_https: false, client_args: ['--verbose'], export_json: nil
      )
      mgr = described_class.new(cfg)
      allow(mgr).to receive_messages(spawn_child: 999, puts: nil)
      mgr.send(:spawn_client)
      expect(mgr).to have_received(:spawn_child)
        .with(['client', '--verbose'], 'client.stdout.log', 'client.stderr.log')
    end

    it 'announces the client pid' do
      manager.send(:spawn_client)
      expect(manager).to have_received(:puts).with('[Harness] Started client with PID 999')
    end
  end

  describe '#spawn_child' do
    it 'spawns the resolved interpreter and absolute bin path with the args, redirecting both streams' do
      allow(Process).to receive(:spawn).and_return(777)
      pid = manager.send(:spawn_child, %w[server --https], 'o.log', 'e.log')
      expected_command = Shellwords.join([RbConfig.ruby, described_class::BIN_PATH, 'server', '--https'])
      expect(Process).to have_received(:spawn).with(
        expected_command,
        out: File.join(log_dir, 'o.log'),
        err: File.join(log_dir, 'e.log')
      )
      expect(pid).to eq(777)
    end
  end

  describe '#wait_for_server' do
    it 'returns as soon as the HTTP port (8080) is open, before any backoff sleep' do
      allow(manager).to receive_messages(port_open?: true, dead?: false)
      allow(manager).to receive(:sleep)
      record_pid(:server, 111)
      t = Time.now
      allow(Time).to receive(:now).and_return(t, t, t + 100)
      expect { manager.send(:wait_for_server) }.not_to output.to_stderr
      expect(manager).to have_received(:port_open?).with(8080)
      expect(manager).not_to have_received(:sleep)
    end

    it 'probes the HTTPS port (8443) when HTTPS is enabled' do
      cfg = HttpLoader::Harness::Config.new(
        target_urls: [], connections: 1, use_https: true, client_args: [], export_json: nil
      )
      mgr = described_class.new(cfg)
      allow(mgr).to receive_messages(port_open?: true, dead?: false)
      mgr.instance_variable_get(:@pids)[:server] = 111
      mgr.send(:wait_for_server)
      expect(mgr).to have_received(:port_open?).with(8443)
    end

    it 'breaks (without a further backoff sleep) and warns when the server dies before binding' do
      allow(manager).to receive_messages(port_open?: false, dead?: true)
      allow(manager).to receive(:sleep)
      record_pid(:server, 111)
      t = Time.now
      allow(Time).to receive(:now).and_return(t, t, t + 100)
      expect { manager.send(:wait_for_server) }.to output(/did not become ready/).to_stderr
      expect(manager).not_to have_received(:sleep)
      expect(manager).to have_received(:dead?).with(111)
    end

    it 'does not probe liveness while no server pid is recorded yet' do
      allow(manager).to receive_messages(port_open?: false, dead?: false, sleep: nil)
      t = Time.now
      allow(Time).to receive(:now).and_return(t, t, t + 100)
      manager.send(:wait_for_server) # @pids has no :server
      expect(manager).not_to have_received(:dead?)
    end

    it 'backs off 0.1s per poll and warns (naming the port and timeout) after the deadline elapses' do
      allow(manager).to receive_messages(port_open?: false, dead?: false)
      allow(manager).to receive(:sleep)
      t = Time.now
      allow(Time).to receive(:now).and_return(t, t, t + 100)
      record_pid(:server, 111)
      expect { manager.send(:wait_for_server) }
        .to output("[Harness] Warning: server did not become ready on port 8080 within 15.0s.\n").to_stderr
      expect(manager).to have_received(:sleep).with(0.1)
    end
  end

  describe '#port_open?' do
    it 'opens and closes a TCP connection to localhost and returns true on success' do
      socket = instance_double(TCPSocket, close: nil)
      allow(TCPSocket).to receive(:new).with('127.0.0.1', 8080).and_return(socket)
      expect(manager.send(:port_open?, 8080)).to be(true)
      expect(socket).to have_received(:close)
    end

    it 'returns false when the connection is refused' do
      allow(TCPSocket).to receive(:new).and_raise(Errno::ECONNREFUSED)
      expect(manager.send(:port_open?, 8080)).to be(false)
    end
  end
end
