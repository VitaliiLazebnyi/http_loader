#!/usr/bin/env ruby
# typed: false
# frozen_string_literal: true

# Fails when `bundle outdated` reports a gem that is not on the documented hold list
# (script/outdated_holds.yml), or when a listed hold is no longer outdated.

require 'open3'
require 'yaml'

root = File.expand_path('..', __dir__)
holds = YAML.safe_load_file(File.join(root, 'script', 'outdated_holds.yml'))

output, = Open3.capture2e('bundle', 'outdated', '--parseable', chdir: root)
pattern = /^(\S+) \(newest ([^,\s]+), installed ([^,)\s]+)/
outdated = output.scan(pattern).to_h { |name, newest, installed| [name, [newest, installed]] }

unexpected = outdated.reject { |name, (newest, _)| holds.dig(name, 'newest') == newest }
stale = holds.keys - outdated.keys

outdated.each do |name, (newest, installed)|
  puts "outdated: #{name} #{installed} -> #{newest}#{' (on hold)' if holds.key?(name)}"
end
unexpected.each { |name, (newest, installed)| warn "NOT ON THE HOLD LIST: #{name} #{installed} -> #{newest}" }
stale.each { |name| warn "STALE HOLD (no longer outdated): #{name}" }
exit(unexpected.empty? && stale.empty? ? 0 : 1)
