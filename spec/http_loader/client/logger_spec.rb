# typed: true
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'http_loader/client/logger'
require 'spec_helper'
require 'tmpdir'

RSpec.describe(HttpLoader::Client::Logger) do
  let(:logger)   { HttpLoader::Client::Logger.new(true) }
  let(:tmp_dir)  { Dir.mktmpdir                         }
  let(:log_path) { File.join(tmp_dir, 'client.log')     }
  let(:err_path) { File.join(tmp_dir, 'client.err')     }

  before { logger.instance_variable_set(:@log_dir, tmp_dir) }
  after { FileUtils.remove_entry(tmp_dir) }

  describe 'CHANNELS' do
    it 'maps each channel to its file and is frozen', :aggregate_failures do
      expect(HttpLoader::Client::Logger::CHANNELS).to(eq(info: 'client.log', error: 'client.err'))
      expect(HttpLoader::Client::Logger::CHANNELS.frozen?).to(be(true))
    end
  end

  describe '#initialize' do
    it 'defaults @log_dir to the logs directory three levels above the sources' do
      # lib/http_loader/client (source) and spec/http_loader/client (here) sit at the same depth,
      # so '../../../logs' resolves to the same repo-level logs directory from either base.
      expect(HttpLoader::Client::Logger.new(false).instance_variable_get(:@log_dir))
        .to(eq(File.expand_path('../../../logs', __dir__)))
    end

    it 'stores the verbose flag as given', :aggregate_failures do
      expect(HttpLoader::Client::Logger.new(true).instance_variable_get(:@verbose)).to(be(true))
      expect(HttpLoader::Client::Logger.new(false).instance_variable_get(:@verbose)).to(be(false))
    end

    it 'buffers through a fresh Async::Queue' do
      expect(HttpLoader::Client::Logger.new(false).instance_variable_get(:@log_queue).is_a?(Async::Queue)).to(be(true))
    end
  end

  describe '#prepare_files' do
    it 'creates both log files', :aggregate_failures do
      logger.prepare_files
      expect(File).to(exist(log_path))
      expect(File).to(exist(err_path))
    end

    it 'truncates pre-existing content in both files (Logger is the sole writer)', :aggregate_failures do
      File.write(log_path, 'stale log')
      File.write(err_path, 'stale err')
      logger.prepare_files
      expect(File.read(log_path)).to(eq(''))
      expect(File.read(err_path)).to(eq(''))
    end

    it 'creates the log directory when it does not exist yet' do
      logger.instance_variable_set(:@log_dir, File.join(tmp_dir, 'nested', 'logs'))
      logger.prepare_files
      expect(File).to(exist(File.join(tmp_dir, 'nested', 'logs', 'client.log')))
    end
  end

  describe 'enqueueing' do
    # Time.now is stubbed so the timestamp is deterministic, and so dropping `.utc` is visible.
    before do
      utc = Time.utc(2021, 1, 2, 3, 4, 5)
      allow(Time).to(receive(:now).and_return(instance_double(Time, utc: utc, iso8601: 'NOT-UTC-ISO')))
    end

    it 'queues an info message with the UTC iso8601 timestamp' do
      logger.info('hello')
      expect(logger.instance_variable_get(:@log_queue).pop).to(eq([:info, '[2021-01-02T03:04:05Z] hello']))
    end

    it 'drops an info message when not verbose' do
      quiet = HttpLoader::Client::Logger.new(false)
      quiet.info('test')
      expect(quiet.instance_variable_get(:@log_queue).size).to(eq(0))
    end

    it 'always queues a status message, regardless of verbosity, on the info channel' do
      quiet = HttpLoader::Client::Logger.new(false)
      quiet.status('code 500')
      expect(quiet.instance_variable_get(:@log_queue).pop).to(eq([:info, '[2021-01-02T03:04:05Z] code 500']))
    end

    it 'queues an error message with the UTC iso8601 timestamp' do
      logger.error('failed')
      expect(logger.instance_variable_get(:@log_queue).pop).to(eq([:error, '[2021-01-02T03:04:05Z] failed']))
    end
  end

  describe '#write_msg' do
    before { logger.prepare_files }

    it 'appends an info message to client.log only', :aggregate_failures do
      logger.__send__(:write_msg, [:info, 'hello'])
      expect(File.read(log_path)).to(eq("hello\n"))
      expect(File.read(err_path)).to(eq(''))
    end

    it 'appends an error message to client.err only', :aggregate_failures do
      logger.__send__(:write_msg, [:error, 'boom'])
      expect(File.read(err_path)).to(eq("boom\n"))
      expect(File.read(log_path)).to(eq(''))
    end

    it 'drops a message on an unknown channel', :aggregate_failures do
      logger.__send__(:write_msg, [:unknown, 'diff'])
      expect(File.read(log_path)).to(eq(''))
      expect(File.read(err_path)).to(eq(''))
    end

    it 'appends successive messages rather than truncating' do
      logger.__send__(:write_msg, [:info, 'a'])
      logger.__send__(:write_msg, [:info, 'b'])
      expect(File.read(log_path)).to(eq("a\nb\n"))
    end
  end

  describe '#flush' do
    before { logger.prepare_files }

    it 'drains queued info and error messages to their files', :aggregate_failures do
      logger.info('test info')
      logger.error('test err')
      logger.flush
      expect(File.read(log_path).include?('test info')).to(be(true))
      expect(File.read(err_path).include?('test err')).to(be(true))
    end

    it 'leaves the files untouched when the queue is empty' do
      logger.flush
      expect(File.read(log_path)).to(eq(''))
    end

    it 'rescues a write error during flush' do
      logger.info('x')
      allow(File).to(receive(:write).and_raise(StandardError))
      expect { logger.flush }
        .not_to(raise_error)
    end
  end

  describe '#run_task / #poll_queue (within the reactor)' do
    before do
      logger.prepare_files
      Async do |task|
        logger_task = logger.run_task(task)
        logger.info('hello-async')
        logger.error('boom-async')
        # Wait (bounded) until the logger fiber has written the last queued message.
        deadline = Time.now + 5.0
        sleep(0.01) until File.read(err_path).include?('boom-async') || Time.now > deadline
        # Async::Task#stop must interrupt the blocking dequeue, or the reactor never returns.
        logger_task.stop
      end
    end

    it('drains info messages to client.log') { expect(File.read(log_path).include?('hello-async')).to(be(true)) }
    it('drains error messages to client.err') { expect(File.read(err_path).include?('boom-async')).to(be(true)) }
  end
end
