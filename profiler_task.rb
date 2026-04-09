# profiler_task.rb
require 'memory_profiler'
require 'ruby-prof'
require 'net/http'
require 'uri'
require 'async'

uri = URI('http://127.0.0.1:8080')
http_args = { read_timeout: nil }

puts "[Profiler] Collecting Ruby Data Structure Metrics (MemoryProfiler)..."

report = MemoryProfiler.report do
  begin
    Async do |task|
      50.times do
        task.async do
          begin
            Net::HTTP.start(uri.host, uri.port, **http_args) do |http|
              req = Net::HTTP::Head.new(uri)
              req['Connection'] = 'keep-alive'
              http.request(req)
            end
          rescue => e
            # ignore connection errors during profile spinup
          end
        end
      end
    end
  rescue
  end
end

File.open("profile_data.txt", "w") do |f|
  report.pretty_print(f, scale_bytes: true, normalize_paths: true)
end

puts "[Profiler] Collecting Ruby Code Execution Metrics (RubyProf)..."
prof_result = RubyProf::Profile.new.profile do
  begin
    Async do |task|
      20.times do
        task.async do
          begin
            Net::HTTP.start(uri.host, uri.port, **http_args) do |http|
              req = Net::HTTP::Head.new(uri)
              req['Connection'] = 'keep-alive'
              http.request(req)
            end
          rescue => e
          end
        end
      end
    end
  rescue
  end
end

printer = RubyProf::FlatPrinter.new(prof_result)
File.open("profile_cpu.txt", "w") do |f|
  printer.print(f, min_percent: 1)
end

puts "[Profiler] Profiling complete, data written to profile_data.txt and profile_cpu.txt."
