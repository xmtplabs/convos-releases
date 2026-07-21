# frozen_string_literal: true

require "date"
require "dry/monads"
require_relative "config"
require_relative "state_writer"

module Train
  # Edits release-config.yml on main through the shared StateWriter loop.
  # The edit is a surgical rewrite of the `skip-dates:` inline-array line —
  # never a YAML re-serialize, which would destroy the file's comments. An
  # unrecognized line shape (someone converted it to block style) fails
  # loudly instead of guessing.
  class ConfigEdit
    include Dry::Monads[:result]
    extend Dry::Monads[:result]

    SKIP_LINE_RE = /^(?<prefix>skip-dates:\s*)\[(?<entries>[^\]]*)\](?<trailer>\s*(?:#.*)?)$/

    # Pure text transform, independently testable: Success([:changed, text])
    # with the date inserted in sorted order (quoted, comment/trailer
    # preserved), Success([:unchanged, text]) when already present,
    # Failure(msg) when the skip-dates line isn't the expected inline array.
    def self.add_to_text(text, date)
      lines = text.lines
      # Broader than SKIP_LINE_RE: also catches a second key in BLOCK style
      # (e.g. a stray `skip-dates:` followed by `  - 2026-11-26` items),
      # which YAML's last-key-wins would otherwise silently no-op the edit.
      any_skip_re = /^skip-dates:/
      if lines.grep(any_skip_re).size > 1
        return Failure("release-config.yml has multiple skip-dates lines — fix it by hand")
      end

      idx = lines.index { |l| l.match?(SKIP_LINE_RE) }
      unless idx
        return Failure("release-config.yml skip-dates line is not the expected inline array — edit it by hand")
      end

      m = lines[idx].match(SKIP_LINE_RE)
      entries = m[:entries].split(",").map { |e| e.strip.delete(%q{"'}) }.reject(&:empty?)
      return Success([:unchanged, text]) if entries.include?(date)

      entries = (entries + [date]).sort
      rendered = entries.map { |e| "\"#{e}\"" }.join(", ")
      lines[idx] = "#{m[:prefix]}[#{rendered}]#{m[:trailer]}\n"
      Success([:changed, lines.join])
    end

    def initialize(github:, out: $stdout)
      @gh = github
      @out = out
      @writer = StateWriter.new(github: github, out: out)
    end

    # Validates then writes. Idempotent end to end: already-listed dates
    # succeed without a commit (StateWriter treats no-change as success).
    def add_skip_date(date:, requested_by: nil)
      parsed = begin
        Date.iso8601(date.to_s)
      rescue ArgumentError, TypeError
        return Failure("add-skip-date: '#{date}' is not an ISO date (YYYY-MM-DD)")
      end
      unless date == parsed.iso8601
        return Failure("add-skip-date: '#{date}' is not an ISO date (YYYY-MM-DD)")
      end
      today = Config.today_et
      if parsed < today
        return Failure("add-skip-date: #{date} is in the past (ET today is #{today.iso8601})")
      end

      if @gh.dry_run
        @out.puts "[dry-run] would add #{date} to skip-dates in release-config.yml"
        return Success(true)
      end

      by = requested_by.to_s.empty? ? "manual" : requested_by
      @writer.write(message: "train: skip #{date} (via #{by})") do |dir|
        path = File.join(dir, "release-config.yml")
        next Failure("no release-config.yml in clone") unless File.exist?(path)

        self.class.add_to_text(File.read(path), date).fmap do |state, text|
          if state == :unchanged
            @out.puts "skip-dates: #{date} already present, skipping"
          else
            File.write(path, text)
          end
          true
        end
      end
    end
  end
end
