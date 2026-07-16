# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "dry/monads"
require_relative "manifest"
require_relative "versions"
require_relative "notes"
require_relative "github"
require_relative "cut"
require_relative "config"
require_relative "outputs"

module Train
  # Cuts a patch release (base patch+1) from the LATEST v* tag on both app
  # repos rather than from dev. Runs FROM a checkout of convos-releases (cwd)
  # and commits directly there, like Cut.
  #
  # Version comes purely from --base-tag arithmetic (no "agree on version"
  # step). Reconcile mode: if the manifest already exists, #run verifies it's
  # "hotfix"-kind with matching source-shas, then proceeds straight to the
  # per-repo branch/PR ensure-state steps.
  class Hotfix
    include Dry::Monads[:result, :do]

    def initialize(github:, releases_dir: Dir.pwd, out: $stdout, err: $stderr)
      @gh = github
      @releases_dir = releases_dir
      @out = out
      @err = err
    end

    # Exactly vX.Y.Z — looser forms crash the patch arithmetic (v2.1) or
    # silently drop components (v2.1.0.5).
    BASE_TAG_RE = /\Av\d+\.\d+\.\d+\z/

    # run: Success(:dry_run | :hotfixed) or Failure(message).
    def run(base_tag:, only_repo: nil)
      yield guard_ref
      yield guard_synced_checkout
      unless base_tag.match?(BASE_TAG_RE)
        return Failure("--base-tag must look like vX.Y.Z, got '#{base_tag}'")
      end

      repos = yield participating_repos(only_repo)
      set_bot_remote

      version = base_tag.delete_prefix("v")
      maj, min, patch = version.split(".").map(&:to_i)
      version = "#{maj}.#{min}.#{patch + 1}"
      today = Config.today_et.strftime("%F")

      work = Dir.mktmpdir("train-hotfix-")
      begin
        captures = yield capture_repos(work: work, repos: repos, base_tag: base_tag)

        @out.puts "Cutting hotfix/#{version} from #{base_tag}"

        if @gh.dry_run
          print_dry_run_plan(version: version, repos: repos, captures: captures)
          return Success(:dry_run)
        end

        mdir = File.join(@releases_dir, "releases", version)
        mfile = File.join(mdir, "manifest.yml")
        sha = captures.transform_values { |c| c[:sha] }

        if File.exist?(mfile)
          sha = yield reconcile_manifest(mfile: mfile, mdir: mdir, version: version, repos: repos, sha: sha, base_tag: base_tag)
        else
          yield init_manifest(mfile: mfile, mdir: mdir, version: version, today: today, repos: repos, sha: sha, base_tag: base_tag)
        end

        result = branch_and_pr_all_repos(work: work, version: version, repos: repos, sha: sha)
        Manifest.set_status(mfile, "branched") if result.success?
        persist_statuses(mdir, version)
        yield result

        Outputs.emit({ "cut-version" => version, "cut-kind" => "hotfix" }, out: @out)
        Success(:hotfixed)
      ensure
        FileUtils.remove_entry(work) if Dir.exist?(work)
      end
    end

    private

    # Identical to Cut#guard_ref; too little to bother sharing.
    def guard_ref
      ref = ENV["GITHUB_REF_NAME"]
      return Success(:ok) unless ref && ref != "main"

      Failure("release-cut must run from main (got #{ref})")
    end

    # The checkout must be AT origin/main: a locally-committed manifest
    # whose push failed would otherwise survive into a retry, where
    # reconcile reads it as already-recorded and skips the push — breaking
    # manifest-first. A stale (behind) checkout is refused for the same
    # reason: decisions would be made against old ledger state.
    def guard_synced_checkout
      remote = @gh.ls_remote(@releases_dir, "refs/heads/main")
      return Success(:ok) if remote.empty?

      local = @gh.rev_parse(@releases_dir, "HEAD")
      return Success(:ok) if local == remote

      Failure("convos-releases checkout is not at origin/main (local #{local}, origin #{remote}) — reset/pull, then retry")
    end

    def participating_repos(only_repo)
      return Success(Cut::REPOS) unless only_repo

      unless Cut::REPOS.include?(only_repo)
        return Failure("--repo must be one of #{Cut::REPOS.join(", ")}, got '#{only_repo}'")
      end

      Success([only_repo])
    end

    def set_bot_remote
      token = ENV["GH_TOKEN"]
      return if token.to_s.empty?

      @gh.set_remote_url(@releases_dir, "https://x-access-token:#{token}@github.com/xmtplabs/convos-releases.git")
    end

    # Clones each repo (blob:none keeps tag history), verifies base_tag is its
    # LATEST v* tag, and captures the tag's commit sha. Any tag mismatch fails
    # the whole run before anything is mutated.
    def capture_repos(work:, repos:, base_tag:)
      captures = {}
      repos.each do |repo|
        dir = File.join(work, repo.split("/").last)
        @gh.clone("https://x-access-token:#{ENV["GH_TOKEN"]}@github.com/#{repo}.git", dir, filter: "blob:none")
        latest = @gh.latest_tag(dir, "v*")
        if latest != base_tag
          return Failure("#{base_tag} is not the latest tag on #{repo} (latest: #{latest})")
        end

        # ^{commit} dereferences annotated tags (e.g. tags made in GitHub's
        # release UI) — plain rev-parse would return the tag OBJECT's sha.
        sha = @gh.rev_parse(dir, "#{base_tag}^{commit}")
        @out.puts "#{repo}: #{base_tag} @ #{sha}"
        captures[repo] = { sha: sha }
      end
      Success(captures)
    end

    def print_dry_run_plan(version:, repos:, captures:)
      @out.puts "DRY RUN — plan:"
      repos.each { |repo| @out.puts "  #{repo}: branch hotfix/#{version} @ #{captures[repo][:sha]}; release PR -> main" }
      @out.puts "  convos-releases: releases/#{version}/{manifest.yml,#{notes_files(repos).join(",")}}"
    end

    def notes_files(repos)
      files = repos.map { |repo| repo.end_with?("convos-ios") ? "ios.md" : "android.md" }
      files << "submission-notes.md"
      files
    end

    # A manifest already exists: a rerun reconciles; a repo the manifest
    # doesn't know EXTENDS the train (a hotfix reaching its second platform
    # — both share the base tag, so both land on the same version). Only
    # kind "hotfix" qualifies, and repos already recorded must
    # source-sha-match what the tag resolves to now (a mismatch means
    # base_tag moved). Returns the authoritative shas: recorded for
    # existing repos, freshly captured for extended ones.
    def reconcile_manifest(mfile:, mdir:, version:, repos:, sha:, base_tag:)
      data = Manifest.read(mfile)

      unless data["kind"] == "hotfix"
        return Failure("manifest already exists for #{version} with kind #{data["kind"].inspect} (releases/#{version}/manifest.yml) — expected kind \"hotfix\"")
      end

      # Partition on key presence, not source-sha truthiness — an entry
      # missing its source-sha (bad hand edit) must fail the mismatch check
      # below, not crash add_repo on an already-present key.
      existing, missing = repos.partition { |repo| data.fetch("repos", {}).key?(repo) }
      mismatched = existing.select { |repo| data.dig("repos", repo, "source-sha") != sha[repo] }
      unless mismatched.empty?
        details = mismatched.map { |repo| "#{repo}: manifest has #{data.dig("repos", repo, "source-sha").inspect}, tag now resolves to #{sha[repo].inspect}" }.join("; ")
        return Failure("hotfix #{version} manifest source-sha mismatch (base_tag moved?) — #{details}")
      end

      if missing.any?
        yield extend_manifest(mfile: mfile, mdir: mdir, version: version, repos: missing, sha: sha, base_tag: base_tag)
        @out.puts "Manifest exists — extended to #{missing.join(", ")}."
      else
        @out.puts "Manifest exists — reconcile mode."
      end

      Success(existing.to_h { |repo| [repo, data.dig("repos", repo, "source-sha")] }
                      .merge(missing.to_h { |repo| [repo, sha[repo]] }))
    end

    # extend_manifest: records the new repo(s) and seeds their notes, pushed
    # like the initial manifest commit — manifest first, app repos second.
    def extend_manifest(mfile:, mdir:, version:, repos:, sha:, base_tag:)
      repos.each do |repo|
        Manifest.add_repo(mfile, repo: repo, sha: sha[repo], branch: "hotfix/#{version}")
      end
      write_seed_notes(mdir: mdir, repos: repos, base_tag: base_tag)

      @gh.git_config_bot(@releases_dir)
      @gh.add(@releases_dir, mdir)
      @gh.commit(@releases_dir, "train: extend hotfix #{version} to #{repos.join(", ")}")
      unless @gh.push(@releases_dir, "HEAD:main")
        return Failure("manifest push to convos-releases main failed (non-fast-forward? retry the hotfix)")
      end

      Success(:ok)
    end

    def init_manifest(mfile:, mdir:, version:, today:, repos:, sha:, base_tag:)
      FileUtils.mkdir_p(mdir)
      Manifest.init(mfile, version: version, kind: "hotfix", cut_date: today, repos: sha)
      write_seed_notes(mdir: mdir, repos: repos, base_tag: base_tag)

      @gh.git_config_bot(@releases_dir)
      @gh.add(@releases_dir, mdir)
      @gh.commit(@releases_dir, "train: hotfix #{version}")
      unless @gh.push(@releases_dir, "HEAD:main")
        return Failure("manifest push to convos-releases main failed (non-fast-forward? retry the hotfix)")
      end

      Success(:ok)
    end

    # Seeds a describe-the-fix TEMPLATE per platform file, not PR-derived notes
    # like Cut — the hotfix branch is just the base tag plus a bump commit, so
    # dev PRs since that tag aren't on it. The human cherry-picking the fix
    # fills these in (same pencil-edit flow as regular release notes).
    # Only files that don't exist yet — an extension must never clobber
    # notes a human already edited.
    def write_seed_notes(mdir:, repos:, base_tag:)
      template = +"# Hotfix from #{base_tag}\n\n"
      template << "_#{Notes::HOTFIX_PLACEHOLDER}; this file becomes the store release notes._\n"

      repos.each do |repo|
        name = repo.end_with?("convos-ios") ? "ios.md" : "android.md"
        path = File.join(mdir, name)
        File.write(path, template) unless File.exist?(path)
      end

      submission = +"# Submission notes for hotfix from #{base_tag}\n\n"
      submission << "_For app reviewers: summarize user-visible changes, test-account hints._\n"
      spath = File.join(mdir, "submission-notes.md")
      File.write(spath, submission) unless File.exist?(spath)
    end

    # Runs each repo's branch+PR steps independently, collecting per-repo
    # outcomes so one failure doesn't hide another's (mirrors Cut#ensure_all_repos).
    def branch_and_pr_all_repos(work:, version:, repos:, sha:)
      outcomes = repos.to_h { |repo| [repo, branch_and_pr_repo(work: work, repo: repo, version: version, sha: sha[repo])] }

      mfile = File.join(@releases_dir, "releases", version, "manifest.yml")
      outcomes.each do |repo, result|
        Manifest.set_repo_status(mfile, repo: repo, status: "branched") if result.success?
      end

      failures = outcomes.select { |_repo, result| result.failure? }
      return Success(:ok) if failures.empty?

      Failure(failures.map { |repo, result| "#{repo}: #{result.failure}" }.join("; "))
    end

    # Ensure-state: reruns converge. An existing branch is verified by ancestry
    # (its tip must contain the captured tag sha) since the bump commit means
    # there's no recorded expected tip. PR creation fails loud — a dispatched
    # hotfix has a human watching.
    def branch_and_pr_repo(work:, repo:, version:, sha:)
      dir = File.join(work, repo.split("/").last)
      branch = "hotfix/#{version}"

      yield ensure_hotfix_branch(dir: dir, repo: repo, branch: branch, version: version, sha: sha)
      ensure_hotfix_pr(repo: repo, branch: branch, version: version)

      Success(:ok)
    rescue Github::ApiError, Github::CommandError, Versions::Error => e
      Failure("#{e.class}: #{e.message}")
    end

    def ensure_hotfix_branch(dir:, repo:, branch:, version:, sha:)
      existing = @gh.ls_remote(dir, "refs/heads/#{branch}")
      if existing.empty?
        @gh.checkout_branch(dir, branch, sha)
        Versions.bump(dir, version)
        @gh.git_config_bot(dir)
        @gh.commit(dir, "chore: hotfix bump to #{version}", all: true)
        unless @gh.push(dir, branch, force: false)
          return Failure("failed to push #{branch}")
        end
        @out.puts "#{repo}: created #{branch} @ #{sha}"
      else
        unless @gh.ancestor?(dir, sha, existing)
          return Failure("#{branch} exists but #{sha} was not confirmed reachable from its tip #{existing} — a pre-existing/foreign branch, or the tip landed after this run's clone (re-dispatching re-checks against a fresh clone); inspect before proceeding")
        end

        @out.puts "#{repo}: #{branch} exists"
      end
      Success(:ok)
    end

    def ensure_hotfix_pr(repo:, branch:, version:)
      open_pr = @gh.pr_list(repo: repo, head: branch, base: "main", state: "open")
      unless open_pr.empty?
        @out.puts "#{repo}: hotfix PR exists"
        return
      end

      merged_pr = @gh.pr_list(repo: repo, head: branch, base: "main", state: "all").find { |pr| pr["merged_at"] }
      if merged_pr
        @out.puts "#{repo}: hotfix PR already merged"
        return
      end

      @gh.pr_create(
        repo: repo, base: "main", head: branch,
        title: "Hotfix #{version}",
        body: hotfix_pr_body(version)
      )
    end

    def hotfix_pr_body(version)
      <<~BODY
        Hotfix release, based on the latest tagged release (patch bump).

        - Notes (edit here): https://github.com/xmtplabs/convos-releases/tree/main/releases/#{version}
        - Manifest: https://github.com/xmtplabs/convos-releases/blob/main/releases/#{version}/manifest.yml

        Every push to this branch uploads a fresh RC (TestFlight / Play internal). Merging stages the store submission.
      BODY
    end

    # Best-effort; "pending" is the truthful state if this push loses a race.
    def persist_statuses(mdir, version)
      return unless @gh.dirty?(@releases_dir, mdir)

      @gh.add(@releases_dir, mdir)
      @gh.commit(@releases_dir, "train: #{version} repo statuses")
      ok = @gh.push(@releases_dir, "HEAD:main")
      loud_warning("status push failed; manifest remains pending") unless ok
    end

    def loud_warning(message)
      if ENV["GITHUB_ACTIONS"] == "true"
        @err.puts "::warning::#{message}"
      else
        @err.puts "train: warning: #{message}"
      end
    end
  end
end
