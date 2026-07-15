# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "dry/monads"
require_relative "github"
require_relative "manifest"

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
      repos, kind = yield read_manifest(version)

      # Phase 1: gate EVERY repo before merging anything.
      permissions = repos.to_h { |repo| [repo, check_permission(repo: repo, actor: actor)] }
      gate_failures = permissions.select { |_repo, result| result.failure? }
      unless gate_failures.empty?
        return Failure(gate_failures.map { |repo, result| "#{repo}: #{result.failure}" }.join("; "))
      end

      # Phase 2: merge each repo (the version's manifest "kind" decides the
      # branch-name prefix — release/<version> or hotfix/<version> — no
      # blind fallback between the two).
      outcomes = repos.to_h { |repo| [repo, merge_repo(repo: repo, version: version, kind: kind)] }

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
        Success([data.fetch("repos", {}).keys, data.fetch("kind")])
      ensure
        FileUtils.remove_entry(dir) if Dir.exist?(dir)
      end
    end

    def describe(result)
      result.success? ? result.value! : result.failure
    end

    # merge_repo: one repo's merge sequence (permission already gated in
    # Phase 1) — find the PR for this version's kind-prefixed branch, then
    # merge it. Wrapped in its own Result so a Failure here never
    # short-circuits the OTHER repo's attempt (run() collects both
    # regardless of outcome).
    def merge_repo(repo:, version:, kind:)
      pr_number = yield find_pr(repo: repo, version: version, kind: kind)
      return Success("already merged") if pr_number == :already_merged

      merge_pr(repo: repo, number: pr_number)
    end

    def check_permission(repo:, actor:)
      permission = @gh.collaborator_permission(repo, actor)
      return Success(permission) if ALLOWED_PERMISSIONS.include?(permission)

      Failure("#{actor} lacks write on #{repo} (got #{permission})")
    end

    # find_pr: looks for an OPEN <kind>/<version> PR (kind is "release" or
    # "hotfix", from the manifest — no blind fallback between the two). If
    # not open, checks state "all" — an already-merged PR is a success-note,
    # not a failure; truly nonexistent is the only hard failure.
    def find_pr(repo:, version:, kind:)
      head = "#{kind}/#{version}"
      open_pr = @gh.pr_list(repo: repo, head: head, base: "main", state: "open").first
      return Success(open_pr.fetch("number")) if open_pr

      merged_pr = @gh.pr_list(repo: repo, head: head, base: "main", state: "all").find { |pr| pr["merged_at"] }
      return Success(:already_merged) if merged_pr

      Failure("no release PR for #{version} on #{repo}")
    end

    def merge_pr(repo:, number:)
      @gh.pr_merge(repo, number, merge_method: "merge")
      Success("merged ##{number}")
    rescue Github::ApiError => e
      Failure(e.message)
    end
  end
end
