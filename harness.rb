# harness.rb
# Run with: ruby harness.rb [connections_count] [--https] [--url=https://example.com]
require 'open3'

$stdout.sync = true

connections = (ARGV[0] || 1000).to_i
use_https = ARGV.include?('--https')
target_url_arg = ARGV.find { |arg| arg.start_with?('--url=') }
target_url = target_url_arg ? target_url_arg.split('=', 2)[1] : nil

if target_url
  ENV['TARGET_URL'] = target_url
  puts "[Harness] Starting test with #{connections} connections to **EXTERNAL URL** #{target_url}."
elsif use_https
  ENV['USE_HTTPS'] = 'true'
  puts "[Harness] Starting test with #{connections} connections over **HTTPS**."
else
  ENV['USE_HTTPS'] = 'false'
  puts "[Harness] Starting test with #{connections} connections over **HTTP**."
end

ENV['MAX_CONNECTIONS'] = connections.to_s

# Attempt to bump FD limits to gracefully handle desired number of connections
begin
  # Adding buffer for stdin/stdout and other handles
  Process.setrlimit(Process::RLIMIT_NOFILE, connections + 1024)
rescue Errno::EPERM
  puts "[Harness] Warning: Could not set RLIMIT_NOFILE automatically."
  puts "          You may encounter file descriptor exhaustion (Errno::EMFILE)"
  puts "          if the connections count exceeds the current OS limit."
  puts "          Suggested to run \`ulimit -n 4096\` manually before running this test."
end

server_pid = nil
if target_url
  puts "[Harness] External target specified. Bypassing local server boot."
else
  # Spawn the server and client, redirecting their output
  server_pid = spawn('ruby server.rb', out: 'server.log', err: 'server.err')
  puts "[Harness] Started server with PID #{server_pid}"
  puts "[Harness] Waiting for server to initialize..."
  sleep 2
end

client_pid = spawn("ruby client.rb #{connections}", out: 'client.log', err: 'client.err')
puts "[Harness] Started client with PID #{client_pid}"

# Ensure we clean up processes when interrupted
trap("INT") do
  puts "\n[Harness] Caught interrupt, cleaning up processes..."
  Process.kill("INT", server_pid) if server_pid rescue nil
  Process.kill("INT", client_pid) if client_pid rescue nil
  exit 0
end

# Helper to capture CPU and memory for a given PID
def process_stats(pid)
  return ["EXTERNAL", "EXTERNAL", 0] if pid.nil?
  out, _ = Open3.capture2("ps -o %cpu,rss -p #{pid}")
  lines = out.strip.split("\n")
  return ["N/A", "N/A", 0] if lines.size < 2

  cpu, rss_kb = lines[1].strip.split(/\s+/)
  rss_mb = (rss_kb.to_f / 1024.0).round(2)
  [cpu, "#{rss_mb} MB", rss_kb.to_f]
rescue
  ["N/A", "N/A", 0]
end

# Helper to aggressively count actual established connections using lsof
def count_established_connections(pid)
  return 0 if pid.nil?
  out, _ = Open3.capture2("lsof -p #{pid} -n -P")
  out.scan(/ESTABLISHED/).count
rescue
  0
end

begin
  puts "[Harness] Monitoring resources (Press Ctrl+C to stop)..."
  header_format = "%-10s | %-11s | %-16s | %-14s | %-14s | %-16s | %-14s | %-14s"
  row_format    = "%-10s | %-11s | %-16s | %-14s | %-14s | %-16s | %-14s | %-14s"
  
  puts "-" * 125
  puts sprintf(header_format, "Time (UTC)", "Real Conns", "Srv CPU/Thrds", "Server Mem", "Srv Mem/Conn", "Cli CPU/Thrds", "Client Mem", "Cli Mem/Conn")
  puts "-" * 125

  start_time = Time.now
  peak_connections = 0

  loop do
    time = Time.now.utc.strftime("%H:%M:%S")
    server_cpu, server_mem, server_kb = process_stats(server_pid)
    client_cpu, client_mem, client_kb = process_stats(client_pid)
    
    if server_pid
      server_threads = begin
        out, _ = Open3.capture2("ps -M -p #{server_pid}")
        [out.strip.split("\n").size - 1, 0].max
      rescue; 0; end
      srv_cpu_info = "#{server_cpu}% / #{server_threads}T"
    else
      srv_cpu_info = "EXTERNAL"
    end
    
    client_threads = begin
      out, _ = Open3.capture2("ps -M -p #{client_pid}")
      [out.strip.split("\n").size - 1, 0].max
    rescue; 0; end
    cli_cpu_info = "#{client_cpu}% / #{client_threads}T"

    active_client_connections = count_established_connections(client_pid)
    active_server_connections = count_established_connections(server_pid)
    
    peak_connections = [peak_connections, active_client_connections].max
    
    if target_url && peak_connections > 0 && active_client_connections == 0
      elapsed = Time.now - start_time
      puts sprintf(row_format, time, active_client_connections, srv_cpu_info, server_mem, server_mem_per_conn, cli_cpu_info, client_mem, client_mem_per_conn)
      puts "\n[Harness] \u26A0\uFE0F EXTERNAL SERVER DISCONNECTED! All TCP Keep-Alive sockets were forcefully dropped."
      puts "[Harness] The endpoints natively survived for mathematically #{elapsed.round(2)} seconds."
      break
    end
    
    if server_pid
      server_mem_per_conn = (server_kb > 0 && active_server_connections > 0) ? "#{(server_kb / active_server_connections.to_f).round(2)} KB" : "N/A"
    else
      server_mem_per_conn = "EXTERNAL"
    end
    
    client_mem_per_conn = (client_kb > 0 && active_client_connections > 0) ? "#{(client_kb / active_client_connections.to_f).round(2)} KB" : "N/A"
    
    # Simple check if either process died unexpectedly
    begin
      Process.getpgid(client_pid)
    rescue Errno::ESRCH
      puts "[Harness] Client process has terminated."
      break
    end
    
    if server_pid
      begin
        Process.getpgid(server_pid)
      rescue Errno::ESRCH
        puts "[Harness] Server process has terminated."
        break
      end
    end
    
    puts sprintf(row_format, time, active_client_connections, srv_cpu_info, server_mem, server_mem_per_conn, cli_cpu_info, client_mem, client_mem_per_conn)
    
    # Check bottlenecks dynamically from error logs
    begin
      full_log = (File.read('client.log') rescue "") + (File.read('client.err') rescue "")
      
      emfile_count  = full_log.scan(/ERROR_EMFILE/).size
      eaddr_count   = full_log.scan(/ERROR_EADDRNOTAVAIL/).size
      thread_errors = full_log.scan(/ERROR_THREADLIMIT/).size
      
      errors = []
      errors << "[OS FDs Limit: #{emfile_count} EMFILE]" if emfile_count > 0
      errors << "[OS Ports Limit: #{eaddr_count} EADDRNOTAVAIL]" if eaddr_count > 0
      errors << "[OS Thread Limit: #{thread_errors} ThreadError]" if thread_errors > 0
      
      if errors.any?
        puts sprintf("   => BOTTLENECK ACTIVE: %s", errors.join(" | "))
      end
    rescue
    end
    
    sleep 2
  end
ensure
  Process.kill("INT", server_pid) if server_pid rescue nil
  Process.kill("INT", client_pid) if client_pid rescue nil
end
