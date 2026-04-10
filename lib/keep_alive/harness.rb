# typed: strict
# frozen_string_literal: true

require 'sorbet-runtime'
require 'open3'

module KeepAlive
  class Harness
    extend T::Sig

    sig { params(connections: Integer, target_url: T.nilable(String), use_https: T::Boolean).void }
    def initialize(connections:, target_url: nil, use_https: false)
      @connections = connections
      @target_url = target_url
      @use_https = use_https
      @server_pid = T.let(nil, T.nilable(Integer))
      @client_pid = T.let(nil, T.nilable(Integer))
      @start_time = T.let(Time.now.utc, Time)
      @peak_connections = T.let(0, Integer)
    end

    sig { void }
    def start
      $stdout.sync = true

      if @target_url
        puts "[Harness] Starting test with #{@connections} connections to **EXTERNAL URL** #{@target_url}."
      elsif @use_https
        puts "[Harness] Starting test with #{@connections} connections over **HTTPS**."
      else
        puts "[Harness] Starting test with #{@connections} connections over **HTTP**."
      end

      bump_file_limits
      spawn_processes

      trap('INT') do
        puts "\n[Harness] Caught interrupt, cleaning up processes..."
        cleanup
        exit(0)
      end

      monitor_resources
    ensure
      cleanup
    end

    private

    sig { void }
    def bump_file_limits
      Process.setrlimit(Process::RLIMIT_NOFILE, @connections + 1024)
    rescue Errno::EPERM
      puts '[Harness] Warning: Could not set RLIMIT_NOFILE automatically.'
      puts '          Suggested to run `ulimit -n 4096` manually before running this test.'
    end

    sig { void }
    def spawn_processes
      unless @target_url
        server_cmd = 'ruby bin/server'
        server_cmd += ' --https' if @use_https
        @server_pid = Process.spawn(server_cmd, out: 'server.log', err: 'server.err')
        puts "[Harness] Started server with PID #{@server_pid}"
        puts '[Harness] Waiting for server to initialize...'
        sleep(2)
      end

      client_cmd = "ruby bin/client --connections_count=#{@connections}"
      client_cmd += ' --https' if @use_https
      client_cmd += " --url=#{@target_url}" if @target_url
      @client_pid = Process.spawn(client_cmd, out: 'client.log', err: 'client.err')
      puts "[Harness] Started client with PID #{@client_pid}"
    end

    sig { void }
    def cleanup
      begin
        Process.kill('INT', T.must(@server_pid)) if @server_pid
      rescue StandardError; nil
      end
      begin
        Process.kill('INT', T.must(@client_pid)) if @client_pid
      rescue StandardError; nil
      end
    end

    sig { params(pid: T.nilable(Integer)).returns([String, String, Float]) }
    def process_stats(pid)
      return ['EXTERNAL', 'EXTERNAL', 0.0] if pid.nil?

      out, _s = Open3.capture2("ps -o %cpu,rss -p #{pid}")
      lines = out.strip.split("\n")
      return ['N/A', 'N/A', 0.0] if lines.size < 2

      cpu, rss_kb = T.must(lines[1]).strip.split(/\s+/)
      rss_mb = (T.must(rss_kb).to_f / 1024.0).round(2)
      [T.must(cpu), "#{rss_mb} MB", T.must(rss_kb).to_f]
    rescue StandardError
      ['N/A', 'N/A', 0.0]
    end

    sig { params(pid: T.nilable(Integer)).returns(Integer) }
    def count_established_connections(pid)
      return 0 if pid.nil?

      out, _s = Open3.capture2("lsof -p #{pid} -n -P")
      out.scan('ESTABLISHED').count
    rescue StandardError
      0
    end

    sig { void }
    def monitor_resources
      puts '[Harness] Monitoring resources (Press Ctrl+C to stop)...'
      header_format = '%-10s | %-11s | %-16s | %-14s | %-14s | %-16s | %-14s | %-14s'
      row_format    = '%-10s | %-11s | %-16s | %-14s | %-14s | %-16s | %-14s | %-14s'

      puts '-' * 125
      puts format(header_format, 'Time (UTC)', 'Real Conns', 'Srv CPU/Thrds', 'Server Mem', 'Srv Mem/Conn',
                  'Cli CPU/Thrds', 'Client Mem', 'Cli Mem/Conn')
      puts '-' * 125

      @start_time = Time.now.utc

      loop do
        time = Time.now.utc.strftime('%H:%M:%S')
        server_cpu, server_mem, server_kb = process_stats(@server_pid)
        client_cpu, client_mem, client_kb = process_stats(@client_pid)

        srv_cpu_info = if @server_pid
                         threads = begin
                           out, _s = Open3.capture2("ps -M -p #{@server_pid}")
                           [out.strip.split("\n").size - 1, 0].max
                         rescue StandardError; 0
                         end
                         "#{server_cpu}% / #{threads}T"
                       else
                         'EXTERNAL'
                       end

        cli_cpu_info = begin
          out, _s = Open3.capture2("ps -M -p #{@client_pid}")
          threads = [out.strip.split("\n").size - 1, 0].max
          "#{client_cpu}% / #{threads}T"
        rescue StandardError
          "#{client_cpu}% / 0T"
        end

        active_client = count_established_connections(@client_pid)
        active_server = count_established_connections(@server_pid)

        @peak_connections = [@peak_connections, active_client].max

        if @target_url && @peak_connections.positive? && active_client.zero?
          elapsed = Time.now.utc - @start_time
          puts format(row_format, time, active_client, srv_cpu_info, server_mem, 'N/A',
                      cli_cpu_info, client_mem, 'N/A')
          puts "\n[Harness] \u26A0\uFE0F EXTERNAL SERVER DISCONNECTED! All TCP Keep-Alive sockets were forcefully dropped."
          puts "[Harness] The endpoints natively survived for mathematically #{elapsed.round(2)} seconds."
          break
        end

        srv_mem_conn = if @server_pid && server_kb.positive? && active_server.positive?
                         "#{(server_kb / active_server.to_f).round(2)} KB"
                       elsif @server_pid.nil?
                         'EXTERNAL'
                       else
                         'N/A'
                       end

        cli_mem_conn = if client_kb.positive? && active_client.positive?
                         "#{(client_kb / active_client.to_f).round(2)} KB"
                       else
                         'N/A'
                       end

        begin
          Process.getpgid(T.must(@client_pid)) if @client_pid
        rescue Errno::ESRCH
          puts '[Harness] Client process has terminated.'
          break
        end

        if @server_pid
          begin
            Process.getpgid(T.must(@server_pid))
          rescue Errno::ESRCH
            puts '[Harness] Server process has terminated.'
            break
          end
        end

        puts format(row_format, time, active_client, srv_cpu_info, server_mem, srv_mem_conn,
                    cli_cpu_info, client_mem, cli_mem_conn)

        check_bottlenecks
        sleep(2)
      end
    end

    sig { void }
    def check_bottlenecks
      full_log = begin
        File.read('client.log')
      rescue StandardError; ''
      end + begin
        File.read('client.err')
      rescue StandardError; ''
      end

      emfile_count  = full_log.scan('ERROR_EMFILE').size
      eaddr_count   = full_log.scan('ERROR_EADDRNOTAVAIL').size
      thread_errors = full_log.scan('ERROR_THREADLIMIT').size

      errors = []
      errors << "[OS FDs Limit: #{emfile_count} EMFILE]" if emfile_count.positive?
      errors << "[OS Ports Limit: #{eaddr_count} EADDRNOTAVAIL]" if eaddr_count.positive?
      errors << "[OS Thread Limit: #{thread_errors} ThreadError]" if thread_errors.positive?

      puts format('   => BOTTLENECK ACTIVE: %s', errors.join(' | ')) if errors.any?
    rescue StandardError
      nil
    end
  end
end
