# typed: strict
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'http_loader/harness'

# Builds the process stats and CPU samples the harness examples use.
module StatsFactory
  extend T::Sig

  # @param cpu [String] the CPU usage
  # @param memory [String] the formatted memory
  # @param kilobytes [Float] the resident memory in kilobytes
  # @param threads [Integer] the thread count
  # @param external [Boolean] whether the process is external
  # @return [HttpLoader::Harness::ProcessStats] the stats
  sig do
    params(
      cpu: String,
      memory: String,
      kilobytes: Float,
      threads: Integer,
      external: T::Boolean
    ).returns(HttpLoader::Harness::ProcessStats)
  end
  def self.stats(cpu: '0.0', memory: '1 MB', kilobytes: 0.0, threads: 1, external: false)
    HttpLoader::Harness::ProcessStats.new(
      cpu: cpu,
      memory: memory,
      kilobytes: kilobytes,
      threads: threads,
      external: external
    )
  end

  # @param stats [HttpLoader::Harness::ProcessStats] the stats
  # @return [Array(String, String, Float, Integer)] the CPU, memory, kilobytes and threads
  sig { params(stats: HttpLoader::Harness::ProcessStats).returns([String, String, Float, Integer]) }
  def self.tuple(stats)
    [stats.cpu, stats.memory, stats.kilobytes, stats.threads]
  end

  # @param ticks [Float] the cumulative jiffies
  # @param time [Time] when they were read
  # @return [HttpLoader::Harness::ResourceMonitor::CpuSample] the sample
  sig { params(ticks: Float, time: Time).returns(HttpLoader::Harness::ResourceMonitor::CpuSample) }
  def self.cpu_sample(ticks, time)
    HttpLoader::Harness::ResourceMonitor::CpuSample.new(ticks: ticks, time: time)
  end
end
