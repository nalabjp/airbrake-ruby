module Airbrake
  ##
  # Represents a cross-Ruby backtrace from exceptions (including JRuby Java
  # exceptions). Provides information about stack frames (such as line number,
  # file and method) in convenient for Airbrake format.
  #
  # @example
  #   begin
  #     raise 'Oops!'
  #   rescue
  #     Backtrace.parse($!, Logger.new(STDOUT))
  #   end
  module Backtrace
    module Patterns
      ##
      # @return [Regexp] the pattern that matches standard Ruby stack frames,
      #   such as ./spec/notice_spec.rb:43:in `block (3 levels) in <top (required)>'
      RUBY = %r{\A
        (?<file>.+)       # Matches './spec/notice_spec.rb'
        :
        (?<line>\d+)      # Matches '43'
        :in\s
        `(?<function>.*)' # Matches "`block (3 levels) in <top (required)>'"
      \z}x

      ##
      # @return [Regexp] the pattern that matches JRuby Java stack frames, such
      #  as org.jruby.ast.NewlineNode.interpret(NewlineNode.java:105)
      JAVA = %r{\A
        (?<function>.+)  # Matches 'org.jruby.ast.NewlineNode.interpret'
        \(
          (?<file>
            (?:uri:classloader:/.+(?=:)) # Matches '/META-INF/jruby.home/protocol.rb'
            |
            (?:uri_3a_classloader_3a_.+(?=:)) # Matches 'uri_3a_classloader_3a_/gems/...'
            |
            [^:]+        # Matches 'NewlineNode.java'
          )
          :?
          (?<line>\d+)?  # Matches '105'
        \)
      \z}x

      ##
      # @return [Regexp] the pattern that tries to assume what a generic stack
      #   frame might look like, when exception's backtrace is set manually.
      GENERIC = %r{\A
        (?:from\s)?
        (?<file>.+)              # Matches '/foo/bar/baz.ext'
        :
        (?<line>\d+)?            # Matches '43' or nothing
        (?:
          in\s`(?<function>.+)'  # Matches "in `func'"
        |
          :in\s(?<function>.+)   # Matches ":in func"
        )?                       # ... or nothing
      \z}x

      ##
      # @return [Regexp] the pattern that matches exceptions from PL/SQL such as
      #   ORA-06512: at "STORE.LI_LICENSES_PACK", line 1945
      # @note This is raised by https://github.com/kubo/ruby-oci8
      OCI = /\A
        (?:
          ORA-\d{5}
          :\sat\s
          (?:"(?<function>.+)",\s)?
          line\s(?<line>\d+)
        |
          #{GENERIC}
        )
      \z/x

      ##
      # @return [Regexp] the pattern that matches CoffeeScript backtraces
      #   usually coming from Rails & ExecJS
      EXECJS = /\A
        (?:
          # Matches 'compile ((execjs):6692:19)'
          (?<function>.+)\s\((?<file>.+):(?<line>\d+):\d+\)
        |
          # Matches 'bootstrap_node.js:467:3'
          (?<file>.+):(?<line>\d+):\d+(?<function>)
        |
          # Matches the Ruby part of the backtrace
          #{RUBY}
        )
      \z/x

      ##
      # @return [Regexp] +EXECJS+ pattern without named captures and
      #   uncommon frames
      EXECJS_SIMPLIFIED = /\A.+ \(.+:\d+:\d+\)\z/
    end

    ##
    # Parses an exception's backtrace.
    #
    # @param [Exception] exception The exception, which contains a backtrace to
    #   parse
    # @return [Array<Hash{Symbol=>String,Integer}>] the parsed backtrace
    def self.parse(exception, logger)
      return [] if exception.backtrace.nil? || exception.backtrace.none?

      regexp = best_regexp_for(exception)

      exception.backtrace.map do |stackframe|
        frame = match_frame(regexp, stackframe)

        unless frame
          logger.error(
            "can't parse '#{stackframe}' (please file an issue so we can fix " \
            "it: https://github.com/airbrake/airbrake-ruby/issues/new)"
          )
          frame = { file: nil, line: nil, function: stackframe }
        end

        stack_frame(frame)
      end
    end

    ##
    # Checks whether the given exception was generated by JRuby's VM.
    #
    # @param [Exception] exception
    # @return [Boolean]
    def self.java_exception?(exception)
      defined?(Java::JavaLang::Throwable) &&
        exception.is_a?(Java::JavaLang::Throwable)
    end

    class << self
      private

      def best_regexp_for(exception)
        if java_exception?(exception)
          Patterns::JAVA
        elsif oci_exception?(exception)
          Patterns::OCI
        elsif execjs_exception?(exception)
          Patterns::EXECJS
        else
          Patterns::RUBY
        end
      end

      def oci_exception?(exception)
        defined?(OCIError) && exception.is_a?(OCIError)
      end

      # rubocop:disable Metrics/PerceivedComplexity, Metrics/CyclomaticComplexity
      def execjs_exception?(exception)
        return false unless defined?(ExecJS::RuntimeError)
        return true if exception.is_a?(ExecJS::RuntimeError)

        if Airbrake::RUBY_20
          # Ruby <2.1 doesn't support Exception#cause. We work around this by
          # parsing backtraces. It's slow, so we check only a few first frames.
          exception.backtrace[0..2].each do |frame|
            return true if frame =~ Patterns::EXECJS_SIMPLIFIED
          end
        elsif exception.cause && exception.cause.is_a?(ExecJS::RuntimeError)
          return true
        end

        false
      end
      # rubocop:enable Metrics/PerceivedComplexity, Metrics/CyclomaticComplexity

      def stack_frame(match)
        { file: match[:file],
          line: (Integer(match[:line]) if match[:line]),
          function: match[:function] }
      end

      def match_frame(regexp, stackframe)
        match = regexp.match(stackframe)
        return match if match

        Patterns::GENERIC.match(stackframe)
      end
    end
  end
end
