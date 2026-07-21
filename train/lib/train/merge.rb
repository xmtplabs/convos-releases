# frozen_string_literal: true

require "dry/monads"
require_relative "github"
require_relative "manifest"
require_relative "versions"

module Train
  # Merges the open release (or hotfix) PR for `version` on every
  # participating app repo. Two-phase: gate every repo's permission before
  # merging any (a partial merge with an unauthorized actor is worse than
  # none). Repos come from the version's OWN manifest, so a single-platform
  # hotfix scopes to exactly its repo.
  class Merge
    include Dry::Monads[:result, :do]

    # Permission levels the actor must hold to merge; the bot token has write
    # regardless of who triggered, so re-check the actor rather than trust it.
    ALLOWED_PERMISSIONS = %w[admin write maintain].freeze

    def initialize(github:, out: $stdout)
      @gh = github
      @out = out
    end

    # run: Success(:ok) once every repo merged or was already merged;
    # Failure(joined per-repo reasons) otherwise. Under dry-run the read-only
    # gate/lookup still run; pr_merge's own mutate! gate no-ops the merge.
    def run(version:, actor:, event_name: nil, requested_by: nil)
      # version comes from a caller-resolved branch name and is used in paths
      # and refs — reject anything that isn't X.Y.Z first.
      unless Versions.valid?(version)
        return Failure("version must look like X.Y.Z, got '#{version}'")
      end

      repos, kind, rc_shas = yield read_manifest(version)

      # Phase 1: gate EVERY repo before merging anything — EXCEPT on the
      # workflow_dispatch path, where Cloudflare Access (the release-dashboard
      # /actions/* app, team-scoped) already authorized the human and GitHub
      # required write to dispatch at all. The collaborator re-check is
      # redundant there and can't run anyway (the dispatch actor is the bot).
      # The comment/workflow_call path keeps the full gate (looser
      # author_association trigger, real human login).
      if event_name == "workflow_dispatch"
        @out.puts "merge dispatched via dashboard by #{requested_by || "unknown"} (permission gate skipped — Access-authorized)"
      else
        permissions = repos.to_h { |repo| [repo, check_permission(repo: repo, actor: actor)] }
        gate_failures = permissions.select { |_repo, result| result.failure? }
        unless gate_failures.empty?
          return Failure(gate_failures.map { |repo, result| "#{repo}: #{result.failure}" }.join("; "))
        end
      end

      # Phase 2: merge each repo; the manifest "kind" decides the branch-name
      # prefix (release/ or hotfix/), no blind fallback.
      outcomes = repos.to_h { |repo| [repo, merge_repo(repo: repo, version: version, kind: kind, rc_shas: rc_shas[repo] || [])] }

      outcomes.each { |repo, result| @out.puts "#{repo}: #{describe(result)}" }

      failures = outcomes.select { |_repo, result| result.failure? }
      return Success(:ok) if failures.empty?

      Failure(failures.map { |repo, result| "#{repo}: #{result.failure}" }.join("; "))
    end

    private

    # The version's manifest "repos" keys + "kind", via a fresh read-only
    # depth-1 clone (nothing here writes state).
    def read_manifest(version)
      @gh.with_releases_clone("train-merge-") do |dir|
        mfile = File.join(dir, "releases", version, "manifest.yml")
        next Failure("no manifest for #{version}") unless File.exist?(mfile)

        data = Manifest.read(mfile)
        repos = data.fetch("repos", {})
        rc_shas = repos.transform_values { |info| (info["rc"] || []).map { |e| e["sha"] } }
        Success([repos.keys, data.fetch("kind"), rc_shas])
      end
    end

    def describe(result)
      result.success? ? result.value! : result.failure
    end

    # One repo's merge sequence (permission already gated): find the PR for
    # this version's kind-prefixed branch, confirm the manifest recorded an RC
    # for its tip, then merge. Wrapped in its own Result so nothing
    # short-circuits the other repo's attempt.
    def merge_repo(repo:, version:, kind:, rc_shas:)
      found = yield find_pr(repo: repo, version: version, kind: kind)
      return Success("already merged") if found == :already_merged

      number, head_sha = found

      # RC gate: merging a tip with no completed RC upload advances main with
      # nothing promotable (promotion would only discover it at find_rc_entry).
      unless rc_shas.include?(head_sha)
        return Failure("no RC recorded for tip #{head_sha} — wait for the RC upload to finish (or check its run), then retry")
      end

      merge_pr(repo: repo, number: number, head: "#{kind}/#{version}", head_sha: head_sha)
    rescue Github::ApiError => e
      Failure(e.message)
    end

    # An API failure here is a per-repo Failure, not an exception — folded
    # into the phase-1 gate report rather than crashing before it exists.
    def check_permission(repo:, actor:)
      permission = @gh.collaborator_permission(repo, actor)
      return Success(permission) if ALLOWED_PERMISSIONS.include?(permission)

      Failure("#{actor} lacks write on #{repo} (got #{permission})")
    rescue Github::ApiError => e
      Failure("permission check failed: #{e.message}")
    end

    # Looks for an OPEN <kind>/<version> PR, returning [number, head-sha]. If
    # none, the LATEST PR for the head decides: merged means already done;
    # closed-unmerged (an abandoned respun release) falls through to failure —
    # an older merged PR is no proof the current one landed.
    def find_pr(repo:, version:, kind:)
      head = "#{kind}/#{version}"
      open_pr = @gh.pr_list(repo: repo, head: head, base: "main", state: "open").first
      return Success([open_pr.fetch("number"), open_pr["head-sha"]]) if open_pr

      latest = @gh.pr_list(repo: repo, head: head, base: "main", state: "all").max_by { |pr| pr["number"] }
      return Success(:already_merged) if latest && latest["merged_at"]

      Failure("no release PR for #{version} on #{repo}")
    end

    # The merge is pinned to the RC-gated tip (GitHub's `sha` guard), so a
    # commit landing in between is rejected rather than merged with no RC. On
    # API error, a re-check downgrades to success when the PR turns out
    # merged — the loser of two concurrent merges must not read as a failure.
    def merge_pr(repo:, number:, head:, head_sha:)
      @gh.pr_merge(repo, number, merge_method: "merge", expected_head_sha: head_sha)
      Success("merged ##{number}")
    rescue Github::ApiError => e
      return Success("already merged") if merged_meanwhile?(repo, head, number)

      Failure(e.message)
    end

    # Scoped to the PR just attempted — a different historical merged PR on
    # the same head (a respun release branch) must not excuse this failure.
    def merged_meanwhile?(repo, head, number)
      @gh.pr_list(repo: repo, head: head, base: "main", state: "all")
         .any? { |pr| pr["number"] == number && pr["merged_at"] }
    rescue Github::ApiError
      false
    end
  end
end
