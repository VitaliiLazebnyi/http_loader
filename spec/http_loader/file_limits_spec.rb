# typed: true
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'spec_helper'

RSpec.describe(HttpLoader::FileLimits) do
  describe '.bump!' do
    before { allow(Process).to(receive(:setrlimit)) }

    it 'raises the soft limit to the desired value, keeping the hard limit' do
      allow(Process).to(receive(:getrlimit).with(Process::RLIMIT_NOFILE).and_return([256, 4096]))
      HttpLoader::FileLimits.bump!(1025)
      expect(Process).to(have_received(:setrlimit).with(Process::RLIMIT_NOFILE, 1025, 4096))
    end

    it 'clamps the desired soft limit to the hard limit, never raising the hard limit' do
      allow(Process).to(receive(:getrlimit).with(Process::RLIMIT_NOFILE).and_return([256, 512]))
      HttpLoader::FileLimits.bump!(1025)
      expect(Process).to(have_received(:setrlimit).with(Process::RLIMIT_NOFILE, 512, 512))
    end

    it 'warns with the default label when the OS rejects the change' do
      allow(Process).to(receive(:getrlimit).and_raise(Errno::EPERM))
      expect { HttpLoader::FileLimits.bump!(1025) }
        .to(output("[http_loader] Warning: Could not set RLIMIT_NOFILE automatically.\n").to_stderr)
    end

    it 'warns with the given label' do
      allow(Process).to(receive(:getrlimit).and_raise(Errno::EPERM))
      expect { HttpLoader::FileLimits.bump!(1025, label: '[Client]') }
        .to(output("[Client] Warning: Could not set RLIMIT_NOFILE automatically.\n").to_stderr)
    end
  end
end
