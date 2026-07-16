# frozen_string_literal: true

require "dry/monads"
require_relative "manifest"
require_relative "state_writer"

module Train
  # Records an uploaded RC's artifact id in the version's manifest, always
  # against whatever is CURRENT on convos-releases main (StateWriter clones
  # fresh per attempt); this class just supplies the mutate block.
  class Append
    include Dry::Monads[:result, :do]

    def initialize(github:, out: $stdout)
      @gh = github
      @out = out
      @writer = StateWriter.new(github: github, out: out)
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

      message = "train: rc #{repo}@#{sha[0, 7]} for #{version}"
      @writer.write(message: message) do |dir|
        mfile = File.join(dir, "releases", version, "manifest.yml")
        next Failure("no manifest for #{version} — was this branch cut by the train?") unless File.exist?(mfile)

        outcome = Manifest.append_rc(mfile, repo: repo, sha: sha, run: run_url, key: key, value: value_str)
        @out.puts "manifest: rc entry for #{sha}/#{key}=#{value_str} already present, skipping" if outcome == :skipped

        Success(true)
      end
    end

    private

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
