# typed: strict
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'English'
require 'rbconfig'
require 'socket'
require 'tempfile'

# Runs bin/http_loader as a subprocess for the integration examples and reads what it leaves behind.
module IntegrationRun
  extend T::Sig

  # The executable under test.
  BIN = T.let(File.expand_path('../../bin/http_loader', __dir__), String)
  private_constant :BIN

  # Where the harness and its children write their logs.
  LOG_DIR = T.let(File.expand_path('../../logs', __dir__), String)
  public_constant :LOG_DIR

  # @param argv [Array<String>] the subcommand and its flags
  # @return [Array(String, String, Process::Status)] stdout, stderr and the exit status
  sig { params(argv: T::Array[String]).returns([String, String, Process::Status]) }
  def self.run(argv)
    Tempfile.create('stderr') do |stderr|
      stdout = IO.popen([RbConfig.ruby, BIN, *argv], err: stderr.path, &:read)
      [stdout, File.read(stderr.path), T.let($CHILD_STATUS, Process::Status)]
    end
  end

  # Starts the gem's own HTTP test server on port 8080 as an external target and waits until it accepts
  # connections.
  #
  # @return [Integer] the server's pid
  sig { returns(Integer) }
  def self.start_server
    pid = Process.spawn(RbConfig.ruby, BIN, 'server', out: File::NULL, err: File::NULL)
    deadline = Time.now + 15.0
    sleep(0.1) until port_open?(8080) || Time.now > deadline
    pid
  end

  # @param port [Integer] a local TCP port
  # @return [Boolean] whether something accepts connections on it
  sig { params(port: Integer).returns(T::Boolean) }
  def self.port_open?(port)
    TCPSocket.new('localhost', port).close
    true
  rescue SystemCallError
    false
  end

  # Reads the client log, polling up to `timeout` for `await` to appear. The client flushes its log
  # asynchronously as the harness tears it down, so a fixed sleep races the flush onto disk under load;
  # waiting for the expected line makes the assertion deterministic.
  #
  # @param await [String] the text to wait for
  # @param timeout [Float] the longest wait in seconds
  # @return [String] the log content (possibly without `await` once the timeout passes)
  sig { params(await: String, timeout: Float).returns(String) }
  def self.client_log(await:, timeout: 15.0)
    path = File.join(LOG_DIR, 'client.log')
    deadline = Time.now + timeout
    loop do
      content = File.exist?(path) ? File.read(path) : ''
      return content if content.include?(await) || Time.now >= deadline

      sleep(0.1)
    end
  end
end
