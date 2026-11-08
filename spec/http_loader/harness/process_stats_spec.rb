# typed: true
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'spec_helper'

RSpec.describe(HttpLoader::Harness::ProcessStats) do
  let(:stats) { HttpLoader::Harness::ProcessStats.measured('12.5', 1536.0, 8) }

  describe '.measured' do
    it 'formats the memory in megabytes, to two decimals, and keeps the rest' do
      expect(stats).to(have_attributes(cpu: '12.5', memory: '1.5 MB', kilobytes: 1536.0, threads: 8, external: false))
    end

    it 'rounds the megabytes to two decimals' do
      expect(HttpLoader::Harness::ProcessStats.measured('0', 1268.0, 1).memory).to(eq('1.24 MB'))
    end
  end

  describe '#load' do
    it('is the CPU percentage and the thread count') { expect(stats.load).to(eq('12.5% / 8')) }
  end

  describe '#per_connection' do
    it 'divides the kilobytes by the connections, to two decimals' do
      expect(stats.per_connection(7)).to(eq('219.43 KB'))
    end

    it('is N/A without connections') { expect(stats.per_connection(0)).to(eq('N/A')) }
    it('is N/A for a negative count') { expect(stats.per_connection(-1)).to(eq('N/A')) }

    it 'is EXTERNAL for an external process' do
      expect(HttpLoader::Harness::ResourceMonitor::EXTERNAL.per_connection(3)).to(eq('EXTERNAL'))
    end
  end

  describe '#columns' do
    it 'is the load, the memory and the memory per connection' do
      expect(stats.columns(2)).to(eq(['12.5% / 8', '1.5 MB', '768.0 KB']))
    end
  end
end
