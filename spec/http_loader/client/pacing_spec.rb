# typed: false
# frozen_string_literal: true

require 'spec_helper'
require 'http_loader/client'

RSpec.describe HttpLoader::Client::Pacing do
  let(:pacer) { Class.new.include(described_class).new }

  describe '#jittered_interval' do
    it 'returns the base unchanged when jitter is zero' do
      expect(pacer.jittered_interval(10.0, 0.0)).to eq(10.0)
    end

    it 'spreads the base upward by base * jitter' do
      allow(pacer).to receive(:rand).and_return(5.0)
      expect(pacer.jittered_interval(10.0, 0.5)).to eq(15.0)
    end

    it 'floors a negative draw at zero' do
      allow(pacer).to receive(:rand).and_return(-20.0)
      expect(pacer.jittered_interval(10.0, 0.5)).to eq(0.0)
    end

    it 'draws from the symmetric +/- variance range' do
      allow(pacer).to receive(:rand) { |range| expect(range).to eq(-5.0..5.0) }.and_return(0.0)
      expect(pacer.jittered_interval(10.0, 0.5)).to eq(10.0)
    end
  end

  describe '#budget_remaining' do
    it 'treats a non-positive timeout as unbounded (nil)' do
      expect(pacer.budget_remaining(0.0, Time.now)).to be_nil
    end

    it 'returns the seconds left before the deadline' do
      expect(pacer.budget_remaining(10.0, Time.now - 3)).to be_within(0.5).of(7.0)
    end

    it 'returns a negative value once the deadline has passed' do
      expect(pacer.budget_remaining(2.0, Time.now - 5)).to be < 0.0
    end
  end

  describe '#cap_to_budget' do
    it 'returns the base unchanged when the budget is unbounded' do
      expect(pacer.cap_to_budget(2.5, nil)).to eq(2.5)
    end

    it 'caps the base down to a smaller remaining budget' do
      expect(pacer.cap_to_budget(5.0, 3.0)).to eq(3.0)
    end

    it 'keeps the base when the remaining budget is larger' do
      expect(pacer.cap_to_budget(2.0, 8.0)).to eq(2.0)
    end
  end
end
