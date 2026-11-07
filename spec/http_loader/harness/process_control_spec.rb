# typed: true
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'spec_helper'

RSpec.describe(HttpLoader::Harness::ProcessControl) do
  let(:manager) { HttpLoader::Harness::ProcessControl }

  describe '.dead?' do
    it 'is false when getpgid resolves the process group' do
      allow(Process).to(receive(:getpgid).with(123).and_return(456))
      expect(manager.dead?(123)).to(be(false))
    end

    it 'is true when getpgid raises ESRCH (no such process)' do
      allow(Process).to(receive(:getpgid).with(123).and_raise(Errno::ESRCH))
      expect(manager.dead?(123)).to(be(true))
    end
  end

  describe '.terminate' do
    before { allow(manager).to(receive(:signal_quietly)) }

    it 'does nothing for a nil pid' do
      manager.terminate(nil)
      expect(manager).not_to(have_received(:signal_quietly))
    end

    context 'when the child is reaped within the 3s grace period' do
      before do
        allow(manager).to(receive(:reaped?).with(556, 3.0).and_return(true))
        manager.terminate(556)
      end

      it('sends SIGINT') { expect(manager).to(have_received(:signal_quietly).with('INT', 556)) }
      it('does not send SIGKILL') { expect(manager).not_to(have_received(:signal_quietly).with('KILL', 556)) }
    end

    context 'when SIGINT does not reap the child' do
      before do
        allow(manager).to(receive(:reaped?).with(556, 3.0).and_return(false))
        allow(manager).to(receive(:reaped?).with(556, 2.0).and_return(true))
        manager.terminate(556)
      end

      it('escalates to SIGKILL') { expect(manager).to(have_received(:signal_quietly).with('KILL', 556)) }
      it('reaps with a 2s deadline') { expect(manager).to(have_received(:reaped?).with(556, 2.0)) }
    end
  end

  describe '.reaped? (private)' do
    it 'returns true as soon as waitpid(WNOHANG) reaps the child' do
      allow(Process).to(receive(:waitpid).with(1, Process::WNOHANG).and_return(1))
      expect(manager.__send__(:reaped?, 1, 1.0)).to(be(true))
    end

    it 'returns true when the child is already gone (ECHILD)' do
      allow(Process).to(receive(:waitpid).and_raise(Errno::ECHILD))
      expect(manager.__send__(:reaped?, 1, 1.0)).to(be(true))
    end

    it 'returns true when the pid is unknown (ESRCH)' do
      allow(Process).to(receive(:waitpid).and_raise(Errno::ESRCH))
      expect(manager.__send__(:reaped?, 1, 1.0)).to(be(true))
    end

    context 'when the child is never reaped' do
      before do
        allow(manager).to(receive(:sleep))
        allow(Process).to(receive(:waitpid).and_return(nil))
      end

      it 'gives up (false) once the deadline passes' do
        expect(manager.__send__(:reaped?, 1, 1.0)).to(be(false))
      end

      it 'polls every 0.05s until the deadline', :aggregate_failures do
        manager.__send__(:reaped?, 1, 0.1)
        expect(Process).to(have_received(:waitpid).with(1, Process::WNOHANG).twice)
        expect(manager).to(have_received(:sleep).with(0.05).twice)
      end

      it 'rounds a partial interval up to one more poll' do
        manager.__send__(:reaped?, 1, 0.12)
        expect(Process).to(have_received(:waitpid).exactly(3).times)
      end
    end
  end

  describe '.signal_quietly (private)' do
    it 'sends the named signal to the pid' do
      allow(Process).to(receive(:kill))
      manager.__send__(:signal_quietly, 'TERM', 42)
      expect(Process).to(have_received(:kill).with('TERM', 42))
    end

    it 'swallows a raised error rather than propagating it' do
      allow(Process).to(receive(:kill).and_raise(Errno::ESRCH))
      expect { manager.__send__(:signal_quietly, 'INT', 42) }
        .not_to(raise_error)
    end
  end
end
