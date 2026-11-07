# typed: true
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

# Every Ruby command of this repository runs with `-w` (all warnings), and the warning gate of every workflow fails
# on any warning. With `-w`, a few of the newest releases of the gem's dependencies and development tools warn
# about their own code while they load (`rake outdated` verifies that none of them has a newer release). Those
# warnings are upstream's: they cannot be fixed in this repository.
#
# RUBYOPT loads this file (`-r`) for every command (script/check and every workflow). It drops exactly the warnings
# listed below, each matched by the gem version, the file and the message; every other warning, from any gem or
# from this repository, is printed as usual and fails the build. An entry stops matching when its gem is updated,
# and must then be removed. The same list is used by leechtop-downloader.
module UpstreamWarnings
  # The pattern of the first line of a warning that `file` (a path below the gems directory, starting with the gem
  # name and version) emits.
  #
  # @param file [String] e.g. "yard-0.9.45/lib/yard/cli/yardoc.rb"
  # @param message [String] a regular expression source matching the message, after "warning: "
  # @return [Regexp] the pattern
  def self.upstream(file, message)
    Regexp.new("/gems/#{Regexp.escape(file)}:\\d+: warning: #{message}\\z")
  end

  # The dropped warnings, each with the gem that emits it.
  KNOWN = {
    # Ruby 4.0 flags IO::Buffer as experimental, and the async fiber scheduler (io-event, a runtime dependency) does
    # its non-blocking file IO through it. The warning names the caller's line, so only the message is matched.
    /: warning: IO::Buffer is experimental and both the Ruby and C interface may change in the future!\z/ =>
      'io-event (async) on Ruby 4.0',
    # A runtime dependency: Falcon's HTTP layer assigns `rescue => error` without using `error`.
    upstream('protocol-http-0.72.1/lib/protocol/http/body/streamable.rb', 'assigned but unused variable - error') =>
      'protocol-http 0.72.1',
    # rubocop-md parses the Markdown files with kramdown: a regular expression of its parser.
    upstream('kramdown-2.5.2/lib/kramdown/parser/base.rb', 'character class has duplicated range: .*') =>
      'kramdown 2.5.2',
    # `tapioca gem`: Tapioca redefines Kernel#exit and #abort on purpose.
    upstream('tapioca-0.20.0/lib/tapioca/runtime/helpers.rb', 'method redefined; discarding old (exit|abort)') =>
      'tapioca 0.20.0',
    # `bundler-audit check`: bundler-audit adds Thor#say_error for the Thor versions that lack it.
    upstream(
      'bundler-audit-0.9.3/lib/bundler/audit/cli/thor_ext/shell/basic/say_error.rb',
      'method redefined; discarding old say_error'
    ) => 'bundler-audit 0.9.3',
    # `yard stats`: YARD sets the default encodings of the process, and has a redundant regular expression.
    upstream('yard-0.9.45/lib/yard/cli/yardoc.rb', 'setting Encoding\.default_(internal|external)') =>
      'yard 0.9.45',
    upstream(
      'yard-0.9.45/lib/yard/templates/helpers/markup/hybrid_markdown.rb',
      'character class has duplicated range'
    ) => 'yard 0.9.45',
    # rubocop-yard parses the YARD tags with YARD, whose types_explainer.rb defines #create_type twice.
    upstream('yard-0.9.45/lib/yard/tags/types_explainer.rb', 'method redefined; discarding old create_type') =>
      'yard 0.9.45',
    # `yard stats`: yard-sorbet 0.9.0, loaded as a YARD plugin, requires yard.rb while yard.rb is still loading.
    %r{warning: loading in progress, circular require considered harmful - \S+/gems/yard-0\.9\.45/lib/yard\.rb\z} =>
      'yard-sorbet 0.9.0'
  }.freeze
  public_constant :KNOWN

  # Prints the warning unless it is one of the known upstream warnings. A warning can span several lines (a
  # backtrace, or the location of a previous definition); the first line identifies it.
  #
  # @param message [String] the warning
  # @param category [Symbol, nil] the warning category
  # @return [void]
  def warn(message, category: nil)
    first_line = message.lines.first.to_s.chomp
    super unless KNOWN.keys.any? { |pattern| pattern.match?(first_line) }
  end
end

Warning.singleton_class.prepend(UpstreamWarnings)
