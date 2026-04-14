# typed: false
# frozen_string_literal: true

require 'spec_helper'
require 'keep_alive/client'
require 'keep_alive/client/error_handler'

RSpec.describe KeepAlive::Client::ErrorHandler do
  let(:dummy_class) do
    Class.new do
      include KeepAlive::Client::ErrorHandler

      attr_reader :logger

      def initialize(logger)
        @logger = logger
      end
    end
  end

  let(:logger) { instance_double(KeepAlive::Client::Logger, error: nil) }
  let(:instance) { dummy_class.new(logger) }

  describe '#handle_err' do
    it 'maps EMFILE intelligently cleanly natively' do
      instance.handle_err(0, Errno::EMFILE.new('dummy file'))
      expect(logger).to have_received(:error).with(/ERROR_EMFILE/)
    end

    it 'maps EADDRNOTAVAIL explicitly cleanly mapping safely' do
      instance.handle_err(1, Errno::EADDRNOTAVAIL.new('dummy addr'))
      expect(logger).to have_received(:error).with(/ERROR_EADDRNOTAVAIL/)
    end

    it 'falls back correctly explicitly to StandardError smoothly' do
      instance.handle_err(2, StandardError.new('custom msg'))
      expect(logger).to have_received(:error).with(/ERROR_OTHER: custom msg/)
    end
  end
end
