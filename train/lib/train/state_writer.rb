# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "retriable"
require "dry/monads"

module Train
  # The shared "clone convos-releases fresh, mutate, commit, push" loop.
  # Every writer (Append's rc entries, Promote's promoted-block) goes through
  # the same clone-fresh-per-attempt + no-change-is-success + retry-on-contention
  # semantics rather than reimplementing it.
  class StateWriter
    include Dry::Monads[:result, :do]

    # Raised when an attempt loses the push race. Retriable retries on exactly
    # this, so a failed clone/commit (CommandError) isn't retried as contention.
    class PushContention < StandardError; end

    TRIES = 3
    BASE_INTERVAL = 3

    def initialize(github:, out: $stdout)
      @gh = github
      @out = out
    end

    # Clones fresh, yields the dir to mutate, then commits (no-change-ok) and
    # pushes HEAD:main — inside a Retriable loop that re-clones each attempt so
    # a losing race re-reads CURRENT main. Returns Success(true) on completion,
    # Failure if retries are exhausted or the block returns a Failure.
    def write(message:, &block)
      outcome = nil
      Retriable.retriable(tries: TRIES, base_interval: BASE_INTERVAL, on: PushContention) do
        outcome = write_once(message: message, &block)
      end
      outcome
    rescue PushContention
      Failure("state write failed after #{TRIES} attempts (push contention?)")
    end

    private

    # Fresh clone; yield; commit; push. Returns the block's Result directly for
    # a hard failure. Raises PushContention ONLY when the push loses a race —
    # clone/config/commit CommandErrors propagate and abort after this one attempt.
    def write_once(message:)
      dir = Dir.mktmpdir("train-state-")
      begin
        @gh.clone(@gh.releases_clone_url, dir, depth: 1)

        result = yield(dir)
        return result if result.is_a?(Dry::Monads::Result::Failure)

        @gh.git_config_bot(dir)
        committed = @gh.commit(dir, message, all: true)
        return Success(true) unless committed # no-change-ok: idempotent rerun, nothing to push.

        raise PushContention unless @gh.push(dir, "HEAD:main")

        Success(true)
      ensure
        FileUtils.remove_entry(dir) if Dir.exist?(dir)
      end
    end
  end
end
