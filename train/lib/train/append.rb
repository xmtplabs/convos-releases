# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "retriable"
require "dry/monads"
require_relative "manifest"

module Train
  # Ports the "Append manifest entry" steps in android-play-internal.yml /
  # ios-testflight-prod.yml. Always clones convos-releases fresh (even if
  # cwd happens to already be a checkout with the manifest) — matching the
  # bash exactly, because the whole point is to append against whatever is
  # CURRENT on main, not a possibly-stale local checkout.
  class Append
    include Dry::Monads[:result, :do]

    # PushContention: raised when a fresh clone/append/commit/push attempt
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

    # run: returns a Result — Success(true) on completion (including
    # dry-run), Failure(message) on hard failure.
    def run(repo:, sha:, run_url:, key:, value:, version: nil)
      value_str = value.to_s
      unless value_str.match?(Manifest::POSITIVE_INT_RE)
        return Failure("id-value must be a positive integer, got '#{value_str}'")
      end

      version ||= version_from_ref(ENV["GITHUB_REF_NAME"])
      unless version
        return Failure("cannot derive version: set GITHUB_REF_NAME to release/X or hotfix/X, or pass --version")
      end

      if @gh.dry_run
        @out.puts "[dry-run] would append rc: repo=#{repo} sha=#{sha} #{key}=#{value_str} run=#{run_url} version=#{version}"
        return Success(true)
      end

      attempt_push(repo: repo, sha: sha, run_url: run_url, key: key, value_str: value_str, version: version)
    end

    private

    def attempt_push(repo:, sha:, run_url:, key:, value_str:, version:)
      outcome = nil
      Retriable.retriable(tries: TRIES, base_interval: BASE_INTERVAL, on: PushContention) do
        outcome = push_once(repo: repo, sha: sha, run_url: run_url, key: key, value_str: value_str, version: version)
      end
      outcome
    rescue PushContention
      Failure("manifest append failed after #{TRIES} attempts (push contention?)")
    end

    # push_once: fresh clone; append; commit; push. Returns the Result
    # directly for a hard (non-retriable) failure, e.g. no manifest for this
    # version. Raises PushContention ONLY when the push itself loses a race
    # (returns false) — clone/config/commit CommandErrors propagate
    # unchanged (they are not "push contention", and Retriable isn't
    # configured to catch/retry them here, so they abort the whole append
    # after this ONE attempt rather than being silently retried under a
    # misleading label).
    def push_once(repo:, sha:, run_url:, key:, value_str:, version:)
      dir = Dir.mktmpdir("train-append-")
      begin
        @gh.clone(
          "https://x-access-token:#{ENV["GH_TOKEN"]}@github.com/xmtplabs/convos-releases.git",
          dir, depth: 1
        )
        mfile = File.join(dir, "releases", version, "manifest.yml")
        return Failure("no manifest for #{version} — was this branch cut by the train?") unless File.exist?(mfile)

        result = Manifest.append_rc(mfile, repo: repo, sha: sha, run: run_url, key: key, value: value_str)
        @out.puts "manifest: rc entry for #{sha}/#{key}=#{value_str} already present, skipping" if result == :skipped

        @gh.git_config_bot(dir)
        committed = @gh.commit(dir, "train: rc #{repo}@#{sha[0, 7]} for #{version}", all: true)
        return Success(true) unless committed # no-change-ok: idempotent rerun, nothing to push.

        raise PushContention unless @gh.push(dir, "HEAD:main")

        Success(true)
      ensure
        FileUtils.remove_entry(dir) if Dir.exist?(dir)
      end
    end

    # version_from_ref: GITHUB_REF_NAME is "release/X" or "hotfix/X" —
    # strip the type prefix, keep the version. Mirrors bash
    # `${GITHUB_REF_NAME#*/}`.
    def version_from_ref(ref)
      return nil if ref.to_s.empty?

      idx = ref.index("/")
      return nil unless idx

      ref[(idx + 1)..]
    end
  end
end
