# frozen_string_literal: true

require_relative 'lib/keep_alive/version'

Gem::Specification.new do |spec|
  spec.name          = 'keep_alive'
  spec.version       = KeepAlive::VERSION
  spec.authors       = ['VitaliiLazebnyi']
  spec.email         = ['author@example.com']

  spec.summary       = 'Keep-Alive High Concurrency Load Testing Framework'
  spec.description   = 'A performance testing tool for HTTP/HTTPS.'
  spec.homepage      = 'https://github.com/VitaliiLazebnyi/keep-alive'
  spec.required_ruby_version = '>= 4.0'

  spec.metadata['allowed_push_host'] = 'https://rubygems.org'
  spec.metadata['source_code_uri']   = spec.homepage

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == __FILE__) ||
        f.match(%r{\A(?:(?:test|spec|features)/|\.(?:git|travis|circleci)|appveyor)})
    end
  end
  spec.bindir        = 'bin'
  spec.executables   = ['keep_alive']
  spec.require_paths = ['lib']

  spec.add_dependency 'async', '~> 2'
  spec.add_dependency 'async-http', '~> 0.65'
  spec.add_dependency 'falcon', '~> 0.44'
  spec.add_dependency 'memory_profiler'
  spec.add_dependency 'rack'
  spec.add_dependency 'rackup'
  spec.add_dependency 'ruby-prof'
  spec.add_dependency 'sorbet-runtime'
end
