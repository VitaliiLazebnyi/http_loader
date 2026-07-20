# typed: false
# frozen_string_literal: true

require 'spec_helper'
require 'http_loader/harness/process_manager'
require 'http_loader/harness/config'

RSpec.describe HttpLoader::Harness::ProcessManager do
  let(:config) { HttpLoader::Harness::Config.new(target_urls: ['http://local'], connections: 1, use_https: false, client_args: [], export_json: nil) }
  let(:manager) { described_class.new(config) }

  describe '#missing_process?' do
    it 'returns natively explicitly successfully smoothly' do
      expect(manager.missing_process?).to be(false)
    end

    it 'evaluates dead? gracefully natively actively' do
      allow(Process).to receive(:getpgid).with(123).and_return(456)
      expect(manager.send(:dead?, 123)).to be(false)
    end

    it 'returns true when server dies gracefully explicitly' do
      cfg = HttpLoader::Harness::Config.new(target_urls: [], connections: 1, use_https: false, client_args: [],
                                            export_json: nil)
      mgr = described_class.new(cfg)

      allow(Process).to receive(:getpgid).and_raise(Errno::ESRCH)
      mgr.instance_variable_set(:@server_pid, 9999)
      expect(mgr.missing_process?).to be(true)
    end

    it 'returns true when client dies gracefully explicitly' do
      allow(Process).to receive(:getpgid).and_raise(Errno::ESRCH)
      manager.instance_variable_set(:@client_pid, 9999)
      expect(manager.missing_process?).to be(true)
    end
  end

  describe '#spawn_processes' do
    it 'spawns sequentially correctly natively' do
      allow(FileUtils).to receive(:mkdir_p)
      allow(Process).to receive(:spawn).and_return(998)
      manager.spawn_processes
      expect(Process).to have_received(:spawn).once
    end

    it 'spawns with https and client_args smoothly' do
      cfg = HttpLoader::Harness::Config.new(target_urls: [], connections: 1, use_https: true, client_args: ['--custom_arg'], export_json: nil)
      mgr = described_class.new(cfg)
      allow(FileUtils).to receive(:mkdir_p)
      allow(mgr).to receive(:port_open?).and_return(true) # server "ready" immediately

      allow(Process).to receive(:spawn).and_return(998, 999)
      mgr.spawn_processes

      expect(Process).to have_received(:spawn).with(/--https/, hash_including(:out, :err))
      expect(Process).to have_received(:spawn).with(/--custom_arg/, hash_including(:out, :err))
    end

    context 'when target_urls is empty' do
      let(:config) { HttpLoader::Harness::Config.new(connections: 1, target_duration: 1.0, target_urls: [], export_json: nil) }

      it 'spawns both server and client' do
        allow(FileUtils).to receive(:mkdir_p)
        allow(Process).to receive(:spawn).and_return(998, 999)
        allow(manager).to receive(:port_open?).and_return(true) # server "ready" immediately
        manager.spawn_processes
        expect(Process).to have_received(:spawn).twice
      end
    end
  end

  describe '#cleanup' do
    it 'rescues exceptions smoothly natively securely' do
      manager.instance_variable_set(:@client_pid, 9999)
      manager.instance_variable_set(:@server_pid, 9998)
      allow(Process).to receive(:kill).and_raise(StandardError)
      expect { manager.cleanup }.not_to raise_error
    end

    it 'does not attempt kill if pids are nil' do
      allow(Process).to receive(:kill)
      manager.cleanup
      expect(Process).not_to have_received(:kill)
    end

    it 'reaps a child that exits on SIGINT without escalating to SIGKILL' do
      manager.instance_variable_set(:@client_pid, 556)
      allow(Process).to receive(:kill)
      allow(manager).to receive(:reaped?).and_return(true)
      manager.cleanup
      expect(Process).to have_received(:kill).with('INT', 556)
      expect(Process).not_to have_received(:kill).with('KILL', 556)
    end

    it 'escalates to SIGKILL when the child is not reaped after SIGINT' do
      manager.instance_variable_set(:@client_pid, 556)
      allow(Process).to receive(:kill)
      allow(manager).to receive(:reaped?).and_return(false, true)
      manager.cleanup
      expect(Process).to have_received(:kill).with('KILL', 556)
    end
  end

  describe '#reaped?' do
    it 'returns true as soon as waitpid reaps the child' do
      allow(Process).to receive(:waitpid).with(1, Process::WNOHANG).and_return(1)
      expect(manager.send(:reaped?, 1, deadline: 1.0)).to be(true)
    end

    it 'returns true when the child is already gone (ECHILD)' do
      allow(Process).to receive(:waitpid).and_raise(Errno::ECHILD)
      expect(manager.send(:reaped?, 1, deadline: 1.0)).to be(true)
    end

    it 'polls then gives up after the deadline' do
      allow(manager).to receive(:sleep)
      allow(Process).to receive(:waitpid).and_return(nil)
      t = Time.now
      allow(Time).to receive(:now).and_return(t, t + 0.5, t + 2)
      expect(manager.send(:reaped?, 1, deadline: 1.0)).to be(false)
      expect(manager).to have_received(:sleep).with(0.05)
    end
  end

  describe '#wait_for_server' do
    it 'returns once the port is open' do
      allow(manager).to receive(:port_open?).and_return(true)
      manager.instance_variable_set(:@server_pid, 111)
      expect { manager.send(:wait_for_server) }.not_to output.to_stderr
    end

    it 'breaks and warns when the server dies before binding' do
      allow(manager).to receive_messages(port_open?: false, dead?: true)
      manager.instance_variable_set(:@server_pid, 111)
      expect { manager.send(:wait_for_server) }.to output(/did not become ready/).to_stderr
    end

    it 'warns after the readiness timeout elapses' do
      allow(manager).to receive_messages(port_open?: false, dead?: false)
      allow(manager).to receive(:sleep)
      t = Time.now
      # (stop_at base, one in-loop iteration, then past the deadline) so the loop body —
      # including the sleep(0.1) backoff — runs exactly once before timing out.
      allow(Time).to receive(:now).and_return(t, t, t + 100)
      manager.instance_variable_set(:@server_pid, 111)
      expect { manager.send(:wait_for_server) }.to output(/did not become ready/).to_stderr
      expect(manager).to have_received(:sleep).with(0.1)
    end
  end

  describe '#port_open?' do
    it 'returns true when a TCP connection succeeds' do
      allow(TCPSocket).to receive(:new).and_return(instance_double(TCPSocket, close: nil))
      expect(manager.send(:port_open?, 8080)).to be(true)
    end

    it 'returns false when the connection is refused' do
      allow(TCPSocket).to receive(:new).and_raise(Errno::ECONNREFUSED)
      expect(manager.send(:port_open?, 8080)).to be(false)
    end
  end
end
