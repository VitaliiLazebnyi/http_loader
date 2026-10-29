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

  def queue(target = logger)
    target.instance_variable_get(:@log_queue)
  end

  # Stubs Time.now so a timestamped message is deterministic, and so dropping `.utc` is visible.
  def freeze_time
    ts = Time.utc(2021, 1, 2, 3, 4, 5)
    allow(Time).to receive(:now).and_return(instance_double(Time, utc: ts, iso8601: 'NOT-UTC-ISO'))
    ts.iso8601
  end

  describe 'CHANNELS' do
    it 'maps each channel to its file and is frozen' do
      expect(described_class::CHANNELS).to eq(info: 'client.log', error: 'client.err')
      expect(described_class::CHANNELS).to be_frozen
    end
  end

  describe '#initialize' do
    it 'defaults @log_dir to the logs directory three levels above the sources' do
      # lib/http_loader/client (source) and spec/http_loader/client (here) sit at the same depth,
      # so '../../../logs' resolves to the same repo-level logs directory from either base.
      expect(described_class.new(false).instance_variable_get(:@log_dir))
        .to eq(File.expand_path('../../../logs', __dir__))
    end

    it 'stores the verbose flag as given' do
      expect(described_class.new(true).instance_variable_get(:@verbose)).to be(true)
      expect(described_class.new(false).instance_variable_get(:@verbose)).to be(false)
    end

    it 'buffers through a fresh Async::Queue' do
      expect(described_class.new(false).instance_variable_get(:@log_queue)).to be_a(Async::Queue)
    end
  end

  describe '#setup_files!' do
    it 'creates both log files' do
      logger.setup_files!
      expect(File).to exist(File.join(tmp_dir, 'client.log'))
      expect(File).to exist(File.join(tmp_dir, 'client.err'))
    end

    it 'truncates pre-existing content in both files (Logger is the sole writer)' do
      File.write(File.join(tmp_dir, 'client.log'), 'stale log')
      File.write(File.join(tmp_dir, 'client.err'), 'stale err')
      logger.setup_files!
      expect(read('client.log')).to eq('')
      expect(read('client.err')).to eq('')
    end

    it 'creates the log directory when it does not exist yet' do
      logger.instance_variable_set(:@log_dir, File.join(tmp_dir, 'nested', 'logs'))
      logger.setup_files!
      expect(File).to exist(File.join(tmp_dir, 'nested', 'logs', 'client.log'))
    end
  end

  describe '#info' do
    it 'enqueues an info tuple carrying the UTC iso8601 timestamp' do
      ts = freeze_time
      logger.info('hello')
      expect(queue.pop).to eq([:info, "[#{ts}] hello"])
    end

    it 'is a no-op when not verbose' do
      quiet = described_class.new(false)
      quiet.info('test')
      expect(queue(quiet).size).to eq(0)
    end
  end

  describe '#status' do
    it 'always enqueues an info tuple regardless of verbosity' do
      ts = freeze_time
      quiet = described_class.new(false)
      quiet.status('code 500')
      expect(queue(quiet).pop).to eq([:info, "[#{ts}] code 500"])
    end
  end

  describe '#error' do
    it 'enqueues an error tuple carrying the UTC iso8601 timestamp' do
      ts = freeze_time
      logger.error('failed')
      expect(queue.pop).to eq([:error, "[#{ts}] failed"])
    end
  end

  describe '#write_msg' do
    before { logger.setup_files! }

    it 'appends an info message to client.log only' do
      logger.send(:write_msg, [:info, 'hello'])
      expect(read('client.log')).to eq("hello\n")
      expect(read('client.err')).to eq('')
    end

    it 'appends an error message to client.err only' do
      logger.send(:write_msg, [:error, 'boom'])
      expect(read('client.err')).to eq("boom\n")
      expect(read('client.log')).to eq('')
    end

    it 'drops a message on an unknown channel' do
      logger.send(:write_msg, [:unknown, 'diff'])
      expect(read('client.log')).to eq('')
      expect(read('client.err')).to eq('')
    end

    it 'appends successive messages rather than truncating' do
      logger.send(:write_msg, [:info, 'a'])
      logger.send(:write_msg, [:info, 'b'])
      expect(read('client.log')).to eq("a\nb\n")
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

    it 'leaves the files untouched when the queue is empty' do
      logger.flush_synchronously!
      expect(read('client.log')).to eq('')
    end

    it 'rescues a write error during flush' do
      logger.info('x')
      allow(File).to receive(:write).and_raise(StandardError)
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
end
