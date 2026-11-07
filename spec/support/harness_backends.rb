# typed: strict
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'http_loader/harness'

# Replaces the resource monitor and process manager of a harness with doubles. Server pid 1 and client
# pid 2 report deliberately different stats so that a field taken from the wrong process is visible.
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
    stats = { server_pid => ['50.0', '100MB', 2048.0, 8], client_pid => ['30.0', '60MB', 1024.0, 4] }
    connections = { server_pid => 16, client_pid => 5 }
    monitor = instance_double(HttpLoader::Harness::ResourceMonitor)
    allow(monitor).to(receive(:process_stats) { |pid| stats.fetch(pid) })
    allow(monitor).to(receive(:count_established_connections) { |pid| connections.fetch(pid) })
    harness.instance_variable_set(:@monitor, monitor)
    pm = instance_double(HttpLoader::Harness::ProcessManager, server_pid: server_pid, client_pid: client_pid)
    harness.instance_variable_set(:@pm, pm)
  end
end
