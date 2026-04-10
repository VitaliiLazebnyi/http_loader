# typed: false
# frozen_string_literal: true

require 'spec_helper'
require 'async'

RSpec.describe KeepAlive::Client do
  let(:connections) { 1 }

  before do
    allow($stdout).to receive(:puts)
    allow(File).to receive(:write)
    allow(File).to receive(:open)
  end

  describe '#start' do
    let(:client) { described_class.new(connections: connections) }

    it 'executes Async logic explicitly', rspec: true do
      expect(client).to receive(:execute_connection).with(0)
      
      # Mock trap to avoid exiting test suite
      allow(client).to receive(:trap).with('INT')
      
      client.start
    end

    context 'when targeting http locally' do
      it 'initializes generic http target correctly', rspec: true do
        expect(client.instance_variable_get(:@protocol_label)).to eq('HTTP')
        expect(client.instance_variable_get(:@uri).to_s).to eq('http://localhost:8080')
      end

      it 'executes the connection safely', rspec: true do
        mock_http = instance_double(Net::HTTP)
        mock_response = instance_double(Net::HTTPSuccess)
        
        allow(Net::HTTP).to receive(:start).and_yield(mock_http)
        allow(mock_http).to receive(:request) do |_, &block|
          block&.call(mock_response)
          mock_response
        end
        allow(mock_response).to receive(:read_body).and_yield("test")
        allow(mock_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
        allow(mock_response).to receive(:is_a?).with(Net::HTTPRedirection).and_return(false)
        
        allow(client).to receive(:sleep)
        
        # We intercept `loop` and break dynamically to test its interior precisely without blocking
        has_looped = false
        allow(client).to receive(:loop) do |&block|
          unless has_looped
            has_looped = true
            block.call
          end
        end

        expect { client.send(:execute_connection, 0) }.not_to raise_error
      end
    end

    context 'when targeting external https' do
      let(:client) { described_class.new(connections: 1, target_url: 'https://example.com', use_https: true) }

      it 'initializes https and external routing correctly', rspec: true do
        expect(client.instance_variable_get(:@protocol_label)).to eq('EXTERNAL HTTPS')
        expect(client.instance_variable_get(:@uri).to_s).to eq('https://example.com')
      end
    end

    context 'when erroring with EMFILE' do
      it 'rescues and buffers the error to Mutex sync log', rspec: true do
        allow(Net::HTTP).to receive(:start).and_raise(Errno::EMFILE, 'Too many open files')
        expect(File).to receive(:open).with('client.err', 'a')
        
        expect { client.send(:execute_connection, 0) }.not_to raise_error
      end
    end
    
    context 'when erroring with EADDRNOTAVAIL' do
      it 'rescues and buffers the error', rspec: true do
        allow(Net::HTTP).to receive(:start).and_raise(Errno::EADDRNOTAVAIL)
        expect(File).to receive(:open).with('client.err', 'a')
        
        expect { client.send(:execute_connection, 0) }.not_to raise_error
      end
    end

    context 'when erroring generally' do
      it 'rescues generic standard errors', rspec: true do
        allow(Net::HTTP).to receive(:start).and_raise(StandardError, 'Misc failure')
        expect(File).to receive(:open).with('client.err', 'a')
        
        expect { client.send(:execute_connection, 0) }.not_to raise_error
      end
    end
  end
end
