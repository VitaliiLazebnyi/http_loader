require 'open3'
env = ENV.to_hash
server = spawn(env, "bundle exec ruby server.rb", out: 'server_test.log', err: 'server_test.log')
sleep 3
client = spawn(env, "bundle exec ruby client.rb 20000", out: 'client_test.log', err: 'client_test.log')
sleep 15
Process.kill("KILL", client) rescue nil
Process.kill("KILL", server) rescue nil
