# typed: strict
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'http_loader/harness'

# Replaces the resource monitor, connection counter and process manager of a harness with doubles. Server pid 1
# and client pid 2 report deliberately different stats so that a field taken from the wrong process is visible.
module HarnessBackends
  extend T::Sig
  extend T::Helpers

  requires_ancestor { RSpec::Core::ExampleGroup }

  # @param harness [HttpLoader::Harness] the harness whose backends are replaced
  # @param server_pid [Integer, nil] the server pid the process manager reports (nil: external server)
  # @param client_pid [Integer, nil] the client pid the process manager reports
  # @return [void]
  sig { params(harness: HttpLoader::Harness, server_pid: T.nilable(Integer), client_pid: T.nilable(Integer)).void }
  def stub_backends(harness, server_pid: 1, client_pid: 2)
    stats = {
      server_pid => StatsFactory.stats(
        cpu: '50.0', memory: '100MB', kilobytes: 2048.0, threads: 8, external: server_pid.nil?
      ),
      client_pid => StatsFactory.stats(
        cpu: '30.0',
        memory: '60MB',
        kilobytes: 1024.0,
        threads: 4,
        external: client_pid.nil?
      )
    }
    monitor = instance_double(HttpLoader::Harness::ResourceMonitor)
    allow(monitor).to(receive(:process_stats) { |pid| stats.fetch(pid) })
    harness.instance_variable_set(:@monitor, monitor)
    stub_processes(harness, server_pid, client_pid)
  end

  # @param harness [HttpLoader::Harness] the harness whose process manager and connection counts are replaced
  # @param server_pid [Integer, nil] the server pid the process manager reports, with 16 connections
  # @param client_pid [Integer, nil] the client pid the process manager reports, with 5 connections
  # @return [void]
  sig { params(harness: HttpLoader::Harness, server_pid: T.nilable(Integer), client_pid: T.nilable(Integer)).void }
  def stub_processes(harness, server_pid, client_pid)
    connections = { server_pid => 16, client_pid => 5 }
    allow(HttpLoader::Harness::ConnectionCounter).to(receive(:count) { |pid| connections.fetch(pid) })
    pm = instance_double(HttpLoader::Harness::ProcessManager, server_pid: server_pid, client_pid: client_pid)
    harness.instance_variable_set(:@pm, pm)
  end
end
