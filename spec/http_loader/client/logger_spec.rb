# typed: false
# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'http_loader/client/logger'

RSpec.describe HttpLoader::Client::Logger do
  let(:logger) { described_class.new(true) }
  let(:tmp_dir) { Dir.mktmpdir }

  before { logger.instance_variable_set(:@log_dir, tmp_dir) }
  after { FileUtils.remove_entry(tmp_dir) }

  def read(name)
    File.read(File.join(tmp_dir, name))
  end

  describe '#setup_files!' do
    it 'creates and truncates both log files (Logger is the sole writer)' do
      logger.setup_files!
      expect(File.exist?(File.join(tmp_dir, 'client.log'))).to be(true)
      expect(File.exist?(File.join(tmp_dir, 'client.err'))).to be(true)
    end

    it 'creates client.log even when not verbose (used by the always-on status channel)' do
      non_verbose = described_class.new(false)
      non_verbose.instance_variable_set(:@log_dir, tmp_dir)
      non_verbose.setup_files!
      expect(File.exist?(File.join(tmp_dir, 'client.log'))).to be(true)
    end
  end

  describe '#info' do
    it 'enqueues when verbose' do
      logger.info('test')
      expect(logger.instance_variable_get(:@log_queue).size).to eq(1)
    end

    it 'is a no-op when not verbose' do
      quiet = described_class.new(false)
      quiet.info('test')
      expect(quiet.instance_variable_get(:@log_queue).size).to eq(0)
    end
  end

  describe '#status' do
    it 'always enqueues regardless of verbosity' do
      quiet = described_class.new(false)
      quiet.status('code 500')
      msg = quiet.instance_variable_get(:@log_queue).pop
      expect(msg.first).to eq(:info)
      expect(msg.last).to include('code 500')
    end
  end

  describe '#error' do
    it 'enqueues under the :error channel' do
      logger.error('failed')
      expect(logger.instance_variable_get(:@log_queue).pop).to include(:error)
    end
  end

  describe '#flush_synchronously!' do
    before { logger.setup_files! }

    it 'drains queued info and error messages to their files' do
      logger.info('test info')
      logger.error('test err')
      logger.flush_synchronously!
      expect(read('client.log')).to include('test info')
      expect(read('client.err')).to include('test err')
    end

    it 'handles an empty queue gracefully' do
      logger.flush_synchronously!
      expect(read('client.log')).to eq('')
    end

    it 'rescues a file error during flush' do
      allow(File).to receive(:open).and_raise(StandardError)
      expect { logger.flush_synchronously! }.not_to raise_error
    end
  end

  describe '#run_task / #poll_queue (within the reactor)' do
    it 'drains enqueued messages to disk and unwinds cleanly when the task stops' do
      logger.setup_files!
      Async do |task|
        logger_task = logger.run_task(task)
        logger.info('hello-async')
        logger.error('boom-async')
        sleep(0.05) # reactor-aware: let the logger fiber process the queue
        logger_task.stop # Async::Task#stop must interrupt the blocking dequeue
      end
      expect(read('client.log')).to include('hello-async')
      expect(read('client.err')).to include('boom-async')
    end
  end

  describe '#write_msg' do
    let(:log) { File.open(File.join(tmp_dir, 'client.log'), 'w') }
    let(:err) { File.open(File.join(tmp_dir, 'client.err'), 'w') }

    after do
      log.close
      err.close
    end

    it 'ignores an unknown target' do
      logger.send(:write_msg, [:unknown, 'diff'], log, err)
      log.flush
      err.flush
      expect(read('client.log')).to eq('')
      expect(read('client.err')).to eq('')
    end

    it 'routes error messages to client.err' do
      logger.send(:write_msg, [:error, 'boom'], log, err)
      err.flush
      expect(read('client.err')).to include('boom')
    end
  end
end
