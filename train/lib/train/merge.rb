# frozen_string_literal: true

require "dry/monads"
require_relative "cut"
require_relative "github"

module Train
  # Ports the "@convos-conductor merge" command: merges the open release (or
  # hotfix) PR for `version` on both app repos. Defense in depth behind the
  # workflow's own guard — re-verifies the actor has push access on each repo
  # before merging anything, via a real (read-only) permission check rather
  # than trusting whoever dispatched the workflow.
  #
  # Both repos are ALWAYS attempted, even if one fails — same collect-then-
  # report shape as Cut#ensure_all_repos — so a permission problem or missing
  # PR on one repo doesn't hide the other repo's outcome (or block its
  # merge). The combined Result is Failure if ANY repo failed, with every
  # repo's outcome folded into the message; Success only when every repo
  # either merged or was already merged.
  class Merge
    include Dry::Monads[:result, :do]

    REPOS = Cut::REPOS

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

    # run: Success(:ok) once every repo either merged or was already merged;
    # Failure(joined per-repo reasons) if any repo failed. Under
    # @gh.dry_run, the permission gate and PR lookup still run for real
    # (read-only) but pr_merge's own mutate! gate no-ops the actual merge —
    # this method never has to check dry_run itself.
    def run(version:, actor:)
      outcomes = REPOS.to_h { |repo| [repo, merge_repo(repo: repo, version: version, actor: actor)] }

      outcomes.each { |repo, result| @out.puts "#{repo}: #{describe(result)}" }

      failures = outcomes.select { |_repo, result| result.failure? }
      return Success(:ok) if failures.empty?

      Failure(failures.map { |repo, result| "#{repo}: #{result.failure}" }.join("; "))
    end

    private

    def describe(result)
      result.success? ? result.value! : result.failure
    end

    # merge_repo: one repo's full sequence — permission gate, then find the
    # release (falling back to hotfix) PR, then merge it. Wrapped in its own
    # Result so a Failure here never short-circuits the OTHER repo's
    # attempt (run() collects both regardless of outcome).
    def merge_repo(repo:, version:, actor:)
      yield check_permission(repo: repo, actor: actor)

      pr_number = yield find_pr(repo: repo, version: version)
      return Success("already merged") if pr_number == :already_merged

      merge_pr(repo: repo, number: pr_number)
    end

    def check_permission(repo:, actor:)
      permission = @gh.collaborator_permission(repo, actor)
      return Success(permission) if ALLOWED_PERMISSIONS.include?(permission)

      Failure("#{actor} lacks write on #{repo} (got #{permission})")
    end

    # find_pr: looks for an OPEN release/<version> PR first, then falls back
    # to hotfix/<version> (hotfix trains use a differently-named branch but
    # otherwise merge the same way). If neither is open, checks state "all"
    # for either head — an already-merged PR is a success-note, not a
    # failure; truly nonexistent is the only hard failure.
    def find_pr(repo:, version:)
      %W[release/#{version} hotfix/#{version}].each do |head|
        open_pr = @gh.pr_list(repo: repo, head: head, base: "main", state: "open").first
        return Success(open_pr.fetch("number")) if open_pr

        merged_pr = @gh.pr_list(repo: repo, head: head, base: "main", state: "all").find { |pr| pr["merged_at"] }
        return Success(:already_merged) if merged_pr
      end

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
