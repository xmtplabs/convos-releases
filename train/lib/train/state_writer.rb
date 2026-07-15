# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "retriable"
require "dry/monads"

module Train
  # StateWriter: the shared "clone convos-releases fresh, mutate it, commit,
  # push" loop originally written inline in Append. Extracted so every
  # writer of convos-releases state (Append's rc entries, Promote's
  # promoted-block) goes through the exact same clone-fresh-per-attempt +
  # no-change-commit-is-success + push-contention-retries-loud semantics,
  # rather than each reimplementing (and potentially drifting from) it.
  class StateWriter
    include Dry::Monads[:result, :do]

    # PushContention: raised when a fresh clone/mutate/commit/push attempt
    # loses the race to another writer. Retriable retries on exactly this
    # error, so a failed `clone` or `commit` (Github::CommandError) does NOT
    # get silently retried as if it were push contention.
    class PushContention < StandardError; end

    TRIES = 3
    BASE_INTERVAL = 3

    def initialize(github:, out: $stdout)
      @gh = github
      @out = out
    end

    # write: clones convos-releases fresh into a tmpdir, yields the dir for
    # the caller to mutate files in, then commits (no-change-ok) and pushes
    # HEAD:main — all inside a Retriable loop that re-clones on every
    # attempt, so a losing race always re-reads whatever's CURRENT on main
    # rather than retrying against a now-stale local tree. Returns a
    # Dry::Monads Result: Success(true) on completion (including a
    # no-op/no-change write), Failure(message) if the retries are exhausted
    # or the block itself returns a Failure (e.g. "no manifest for X").
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

    # write_once: fresh clone; yield to caller; commit; push. Returns the
    # Result directly for a hard (non-retriable) failure surfaced by the
    # block (e.g. Failure("no manifest for ...")). Raises PushContention
    # ONLY when the push itself loses a race (returns false) — clone/config/
    # commit CommandErrors propagate unchanged (they are not "push
    # contention", and Retriable isn't configured to catch/retry them here,
    # so they abort the whole write after this ONE attempt rather than being
    # silently retried under a misleading label).
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
