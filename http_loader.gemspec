# frozen_string_literal: true

require_relative 'lib/http_loader/version'

Gem::Specification.new do |spec|
  spec.name          = 'http_loader'
  spec.version       = HttpLoader::VERSION
  spec.authors       = ['Vitalii Lazebnyi']
  spec.email         = ['vitalii.lazebnyi.github@gmail.com']

  spec.summary       = 'High-concurrency asynchronous load testing console tool for HTTP/HTTPS.'
  spec.description   = 'HttpLoader is a powerful, high-concurrency performance and load testing ' \
                       'console tool. Built on asynchronous Ruby, it evaluates server limits by ' \
                       'opening massive numbers of persistent connections and holding them open. ' \
                       'It utilizes event-driven I/O with optional periodic ping requests to keep ' \
                       'connections active, allowing you to rigorously benchmark maximum concurrent ' \
                       'socket capacity with precision and minimal client-side overhead.'
  spec.homepage      = 'https://github.com/VitaliiLazebnyi/http_loader'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 4.0'
  spec.metadata['allowed_push_host']     = 'https://rubygems.org'
  spec.metadata['source_code_uri']       = 'https://github.com/VitaliiLazebnyi/http_loader'
  spec.metadata['bug_tracker_uri']       = 'https://github.com/VitaliiLazebnyi/http_loader/issues'
  spec.metadata['changelog_uri']         = 'https://github.com/VitaliiLazebnyi/http_loader/blob/main/CHANGELOG.md'
  spec.metadata['rubygems_mfa_required'] = 'true'

  # Signing is opt-in via GEM_SIGN=1 (set by the release workflow) so that ordinary
  # `gem build` on a maintainer machine or in CI never fails on a mismatched/absent key
  # and never silently ships an unsigned gem it believed to be signed. Both the cert
  # chain and the signing key are gated together — declaring cert_chain without a
  # matching key is what breaks `gem build`.
  gem_key = File.expand_path('~/.gem/gem-private_key.pem')
  if ENV['GEM_SIGN'] == '1' && File.exist?(gem_key)
    spec.cert_chain  = ['certs/http_loader-public_cert.pem']
    spec.signing_key = gem_key
  end

  spec.files = %w[
    BUGS.md
    CHANGELOG.md
    Gemfile
    LICENSE.txt
    PERFORMANCE_REPORT.md
    README.md
    REQUIREMENTS.md
    http_loader.gemspec
  ] + Dir.glob('{lib,bin,certs}/**/*', base: __dir__).select do |f|
    File.file?(File.expand_path(f, __dir__))
  end
  spec.bindir        = 'bin'
  spec.executables   = ['http_loader']
  spec.require_paths = ['lib']

  spec.add_dependency 'async', '~> 2.39'
  spec.add_dependency 'async-http', '~> 0.95'
  spec.add_dependency 'falcon', '~> 0.55'
  spec.add_dependency 'rack', '~> 3.2'
  spec.add_dependency 'rackup', '~> 2.3'
  spec.add_dependency 'sorbet-runtime', '~> 0.6'

  spec.add_development_dependency 'memory_profiler', '~> 1.1'
  spec.add_development_dependency 'rake', '~> 13.3'
  spec.add_development_dependency 'rspec', '~> 3.13'
  spec.add_development_dependency 'rubocop', '~> 1.86'
  spec.add_development_dependency 'rubocop-ai', '~> 0.1'
  spec.add_development_dependency 'rubocop-md', '~> 2.0'
  spec.add_development_dependency 'rubocop-performance', '~> 1.26'
  spec.add_development_dependency 'rubocop-rake', '~> 0.7'
  spec.add_development_dependency 'rubocop-rspec', '~> 3.9'
  spec.add_development_dependency 'rubocop-thread_safety', '~> 0.7'
  spec.add_development_dependency 'ruby-prof', '~> 2.0'
  spec.add_development_dependency 'simplecov', '~> 0.22'
  spec.add_development_dependency 'sorbet', '~> 0.6'
  spec.add_development_dependency 'yard', '~> 0.9'
  spec.add_development_dependency 'yard-sorbet', '~> 0.8'
end
