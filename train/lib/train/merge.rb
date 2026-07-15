# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "dry/monads"
require_relative "github"
require_relative "manifest"
require_relative "versions"

module Train
  # Ports the "@convos-conductor merge" command: merges the open release (or
  # hotfix) PR for `version` on every participating app repo. Defense in
  # depth behind the workflow's own guard — re-verifies the actor has push
  # access on each repo before merging anything, via a real (read-only)
  # permission check rather than trusting whoever dispatched the workflow.
  #
  # Participating repos are read from the version's OWN manifest (its
  # "repos" keys), not a hardcoded Cut::REPOS — a single-platform hotfix
  # (--repo filtered, see Hotfix) only has ONE repo in its manifest, and
  # merging would otherwise wrongly attempt the other platform too (no PR
  # to find there, an avoidable Failure).
  #
  # Two-phase: Phase 1 checks EVERY participating repo's permission before
  # ANY merge is attempted — if any repo's gate fails, the whole run is a
  # Failure with ZERO merges attempted anywhere (a partial merge with an
  # unauthorized actor on one repo is worse than no merge at all). Phase 2
  # then merges each repo that passed, using the same collect-then-report
  # shape as Cut#ensure_all_repos so one repo's merge failure doesn't hide
  # (or block) the other's. The combined Result is Failure if ANY repo
  # failed, with every repo's outcome folded into the message; Success only
  # when every repo either merged or was already merged.
  class Merge
    include Dry::Monads[:result, :do]

    # ALLOWED_PERMISSIONS: what collaborator_permission must return for the
    # actor to be allowed to merge — anything less (read/triage/none) is
    # rejected even though the workflow itself is already gated, since this
    # runs with a bot token that has write access regardless of who
    # triggered it.
    ALLOWED_PERMISSIONS = %w[admin write maintain].freeze

    def initialize(github:, out: $stdout)
      @gh = github
      @out = out
    end

    # run: Success(:ok) once every participating repo either merged or was
    # already merged; Failure(joined per-repo reasons) if any repo failed
    # (permission gate OR merge). Under @gh.dry_run, the permission gate and
    # PR lookup still run for real (read-only) but pr_merge's own mutate!
    # gate no-ops the actual merge — this method never has to check dry_run
    # itself.
    def run(version:, actor:)
      # `version` arrives from a caller-resolved branch name and is used in
      # file paths and branch refs — reject anything that isn't X.Y.Z
      # before it touches either.
      unless version.match?(Versions::VERSION_RE)
        return Failure("version must look like X.Y.Z, got '#{version}'")
      end

      repos, kind, rc_shas = yield read_manifest(version)

      # Phase 1: gate EVERY repo before merging anything.
      permissions = repos.to_h { |repo| [repo, check_permission(repo: repo, actor: actor)] }
      gate_failures = permissions.select { |_repo, result| result.failure? }
      unless gate_failures.empty?
        return Failure(gate_failures.map { |repo, result| "#{repo}: #{result.failure}" }.join("; "))
      end

      # Phase 2: merge each repo (the version's manifest "kind" decides the
      # branch-name prefix — release/<version> or hotfix/<version> — no
      # blind fallback between the two).
      outcomes = repos.to_h { |repo| [repo, merge_repo(repo: repo, version: version, kind: kind, rc_shas: rc_shas[repo] || [])] }

      outcomes.each { |repo, result| @out.puts "#{repo}: #{describe(result)}" }

      failures = outcomes.select { |_repo, result| result.failure? }
      return Success(:ok) if failures.empty?

      Failure(failures.map { |repo, result| "#{repo}: #{result.failure}" }.join("; "))
    end

    private

    # read_manifest: the version's OWN manifest "repos" keys + "kind" — read
    # via a fresh, read-only, depth-1 clone of convos-releases (same
    # approach Promote#prepare uses to read manifest state cheaply, without
    # a StateWriter round-trip since nothing here needs to WRITE it). A
    # single-platform hotfix (--repo filtered, see Hotfix) only has ONE repo
    # in its manifest — merging must scope to exactly that, not a hardcoded
    # both-repos list (which would wrongly attempt the other platform: no PR
    # to find there, an avoidable Failure).
    def read_manifest(version)
      dir = Dir.mktmpdir("train-merge-")
      begin
        @gh.clone(
          "https://x-access-token:#{ENV["GH_TOKEN"]}@github.com/xmtplabs/convos-releases.git",
          dir, depth: 1
        )
        mfile = File.join(dir, "releases", version, "manifest.yml")
        return Failure("no manifest for #{version}") unless File.exist?(mfile)

        data = Manifest.read(mfile)
        repos = data.fetch("repos", {})
        rc_shas = repos.transform_values { |info| (info["rc"] || []).map { |e| e["sha"] } }
        Success([repos.keys, data.fetch("kind"), rc_shas])
      ensure
        FileUtils.remove_entry(dir) if Dir.exist?(dir)
      end
    end

    def describe(result)
      result.success? ? result.value! : result.failure
    end

    # merge_repo: one repo's merge sequence (permission already gated in
    # Phase 1) — find the PR for this version's kind-prefixed branch,
    # check the manifest recorded an RC for its tip, then merge it.
    # Wrapped in its own Result — including a rescue for API errors raised
    # by the PR lookup — so nothing here ever short-circuits the OTHER
    # repo's attempt (run() collects both regardless of outcome).
    def merge_repo(repo:, version:, kind:, rc_shas:)
      found = yield find_pr(repo: repo, version: version, kind: kind)
      return Success("already merged") if found == :already_merged

      number, head_sha = found

      # RC gate: merging a tip whose RC upload hasn't completed (or
      # failed) advances main with nothing promotable — promotion would
      # only discover it afterwards, at find_rc_entry.
      unless rc_shas.include?(head_sha)
        return Failure("no RC recorded for tip #{head_sha} — wait for the RC upload to finish (or check its run), then retry")
      end

      merge_pr(repo: repo, number: number, head: "#{kind}/#{version}", head_sha: head_sha)
    rescue Github::ApiError => e
      Failure(e.message)
    end

    # check_permission: an API failure here is a per-repo Failure, not an
    # exception — run() folds it into the phase-1 gate report alongside any
    # other repo's outcome instead of crashing before that report exists.
    def check_permission(repo:, actor:)
      permission = @gh.collaborator_permission(repo, actor)
      return Success(permission) if ALLOWED_PERMISSIONS.include?(permission)

      Failure("#{actor} lacks write on #{repo} (got #{permission})")
    rescue Github::ApiError => e
      Failure("permission check failed: #{e.message}")
    end

    # find_pr: looks for an OPEN <kind>/<version> PR (kind is "release" or
    # "hotfix", from the manifest — no blind fallback between the two),
    # returning [number, head-sha]. If not open, checks state "all" — an
    # already-merged PR is a success-note, not a failure; truly
    # nonexistent is the only hard failure.
    def find_pr(repo:, version:, kind:)
      head = "#{kind}/#{version}"
      open_pr = @gh.pr_list(repo: repo, head: head, base: "main", state: "open").first
      return Success([open_pr.fetch("number"), open_pr["head-sha"]]) if open_pr

      merged_pr = @gh.pr_list(repo: repo, head: head, base: "main", state: "all").find { |pr| pr["merged_at"] }
      return Success(:already_merged) if merged_pr

      Failure("no release PR for #{version} on #{repo}")
    end

    # merge_pr: the merge is pinned to the tip the RC gate just examined
    # (GitHub's `sha` guard) — a commit landing in between is rejected by
    # the API instead of silently merged with no RC. On an API error, a
    # re-check downgrades to a success-note when the PR turns out merged —
    # two concurrent conductor commands (one per repo's PR; concurrency
    # groups don't span repos) both merge both PRs, and the loser's 405
    # would otherwise read as a failed release.
    def merge_pr(repo:, number:, head:, head_sha:)
      @gh.pr_merge(repo, number, merge_method: "merge", expected_head_sha: head_sha)
      Success("merged ##{number}")
    rescue Github::ApiError => e
      return Success("already merged") if merged_meanwhile?(repo, head)

      Failure(e.message)
    end

    def merged_meanwhile?(repo, head)
      @gh.pr_list(repo: repo, head: head, base: "main", state: "all").any? { |pr| pr["merged_at"] }
    rescue Github::ApiError
      false
    end
  end
end
