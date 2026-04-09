# client.rb
# Run with: ruby client.rb
require 'net/http'
require 'uri'
require 'openssl'

if ENV['TARGET_URL']
  uri = URI(ENV['TARGET_URL'])
  protocol_label = "EXTERNAL #{uri.scheme.upcase}"
  if uri.scheme == 'https'
    http_args = { use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_NONE, read_timeout: nil }
  else
    http_args = { read_timeout: nil }
  end
elsif ENV['USE_HTTPS'] == 'true'
  uri = URI('https://localhost:8443')
  protocol_label = "HTTPS"
  http_args = { use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_NONE, read_timeout: nil }
else
  uri = URI('http://localhost:8080')
  protocol_label = "HTTP"
  http_args = { read_timeout: nil }
end

CONNECTIONS = (ARGV[0] || 1000).to_i
puts "[Client] Starting #{CONNECTIONS} #{protocol_label} connections to #{uri}..."
puts "[Client] Note: Output of individual pings is suppressed to avoid console spam."

require 'async'

trap("INT") do
  # Exit cleanly without dumping a stack trace to STDERR
  exit 0
end

Async do |task|
  CONNECTIONS.times do |i|
    # Instead of an OS Thread, we spawn a Fiber natively bound to Epoll/Kqueue
    task.async do
      begin
        # Ruby 4+ natively binds Net::HTTP to the Fiber Scheduler dynamically
        Net::HTTP.start(uri.host, uri.port, **http_args) do |http|
          request = Net::HTTP::Get.new(uri)
          
          # We add a Keep-Alive header explicitly to request persistence
          request['Connection'] = 'keep-alive'
          
          http.request(request) do |response|
            response.read_body do |chunk|
              # Suppressed payload output
            end
          end
          
          # Instead of blindly sleeping, we explicitly verify and control the keep-alive socket
          # by generating a heartbeat ping to guarantee the connection is open and active
          loop do
            sleep 5
            ping_request = Net::HTTP::Head.new(uri)
            ping_request['Connection'] = 'keep-alive'
            response = http.request(ping_request)
            break unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPRedirection)
          end
        end
      rescue Errno::EMFILE => e
        File.open("client.err", "a") { |f| f.puts "[Client #{i}] ERROR_EMFILE: #{e.message}" }
      rescue Errno::EADDRNOTAVAIL => e
        File.open("client.err", "a") { |f| f.puts "[Client #{i}] ERROR_EADDRNOTAVAIL: Ephemeral port limit reached." }
      rescue => e
        File.open("client.err", "a") { |f| f.puts "[Client #{i}] ERROR_OTHER: #{e.message}" }
      end
    end
  end
end