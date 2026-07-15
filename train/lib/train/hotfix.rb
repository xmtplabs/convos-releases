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

module Train
  # Ports a hotfix train: given the LATEST v* release tag on both app repos,
  # cuts a patch release (base patch+1) from that tag rather than from dev.
  # Runs FROM a checkout of convos-releases (cwd), same as Cut — this class
  # commits directly in that checkout (no StateWriter; StateWriter is for
  # Append/Promote's "clone fresh per attempt, retry on push contention"
  # loop, which hotfix.rb doesn't need any more than cut.rb does — both run
  # once, from release-cut.yml, with nothing else concurrently writing the
  # SAME version's manifest).
  #
  # Unlike Cut, there's no "in-flight reconciliation" or "agree on version"
  # step: the version is derived purely from --base-tag arithmetic, and
  # Manifest.init's existing-file refusal is the only collision guard
  # (surfaced as a Failure — no reconcile mode for hotfixes in v1).
  class Hotfix
    include Dry::Monads[:result, :do]

    def initialize(github:, releases_dir: Dir.pwd, out: $stdout, err: $stderr)
      @gh = github
      @releases_dir = releases_dir
      @out = out
      @err = err
    end

    # run: Success(:dry_run | :hotfixed) or Failure(message).
    def run(base_tag:, only_repo: nil)
      yield guard_ref
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
        return Failure("manifest already exists for #{version} (releases/#{version}/manifest.yml)") if File.exist?(mfile)

        sha = captures.transform_values { |c| c[:sha] }
        yield init_manifest(mfile: mfile, mdir: mdir, version: version, today: today, repos: repos, sha: sha, captures: captures)

        result = branch_and_pr_all_repos(work: work, version: version, repos: repos, sha: sha)
        Manifest.set_status(mfile, "branched") if result.success?
        persist_statuses(mdir, version)
        yield result

        Success(:hotfixed)
      ensure
        FileUtils.remove_entry(work) if Dir.exist?(work)
      end
    end

    private

    # guard_ref: identical guard to Cut#guard_ref (4 lines) — not worth
    # extracting to a shared module for this little duplication.
    def guard_ref
      ref = ENV["GITHUB_REF_NAME"]
      return Success(:ok) unless ref && ref != "main"

      Failure("release-cut must run from main (got #{ref})")
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

    # capture_repos: clones each participating repo (blob:none — tag history
    # included), verifies base_tag is that repo's LATEST v* tag, and
    # captures the tag's commit sha + commit date (the notes-seed `since`
    # boundary). Any single repo's tag mismatch fails the whole run before
    # any manifest/branch mutation happens elsewhere.
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
        date = @gh.commit_date(dir, base_tag)
        @out.puts "#{repo}: #{base_tag} @ #{sha} (#{date})"
        captures[repo] = { sha: sha, date: date }
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

    def init_manifest(mfile:, mdir:, version:, today:, repos:, sha:, captures:)
      FileUtils.mkdir_p(mdir)
      Manifest.init(mfile, version: version, kind: "hotfix", cut_date: today, repos: sha)
      write_seed_notes(mdir: mdir, repos: repos, captures: captures)

      @gh.git_config_bot(@releases_dir)
      @gh.add(@releases_dir, mdir)
      @gh.commit(@releases_dir, "train: hotfix #{version}")
      unless @gh.push(@releases_dir, "HEAD:main")
        return Failure("manifest push to convos-releases main failed (non-fast-forward? retry the hotfix)")
      end

      Success(:ok)
    end

    # write_seed_notes: seeds notes per participating platform file (ios.md
    # for convos-ios, android.md for convos-client), since each repo's own
    # base-tag commit date — NOT a shared boundary, since a hotfix on one
    # platform only might be based on a tag cut at a different time than the
    # other's. submission-notes.md is written from whichever platform file
    # exists (android's, if both/neither — matching Cut's own preference for
    # android_notes as the submission body), so --repo filtering to iOS only
    # still produces a submission-notes.md.
    def write_seed_notes(mdir:, repos:, captures:)
      ios_notes = nil
      android_notes = nil

      repos.each do |repo|
        since = captures[repo][:date]
        notes = seed_notes(repo, since)
        if repo.end_with?("convos-ios")
          ios_notes = notes
          File.write(File.join(mdir, "ios.md"), notes)
        else
          android_notes = notes
          File.write(File.join(mdir, "android.md"), notes)
        end
      end

      submission_source = android_notes || ios_notes || ""
      submission = +"# Submission notes for hotfix\n\n"
      submission << "_For app reviewers: summarize user-visible changes, test-account hints._\n\n"
      submission << submission_source
      File.write(File.join(mdir, "submission-notes.md"), submission)
    end

    def seed_notes(repo, since)
      prs = @gh.merged_prs_since(repo, since)
      Notes.format(prs)
    end

    # branch_and_pr_all_repos: runs each repo's branch+PR steps independently
    # and collects Success/Failure per repo, mirroring Cut#ensure_all_repos —
    # a failure on one repo doesn't hide the other's outcome.
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

    # branch_and_pr_repo: create hotfix/<version> LOCALLY at the tag's sha,
    # bump the patch version, commit, and push ONCE — so the branch's tip on
    # origin is the bump commit, and the tag's already-uploaded commit is
    # never rebuilt as a "new" RC. Unlike Cut's release-PR step, PR creation
    # here is NOT best-effort — a dispatch-triggered hotfix has a human
    # watching, so a failure here must fail the whole repo loud rather than
    # silently leave no PR.
    def branch_and_pr_repo(work:, repo:, version:, sha:)
      dir = File.join(work, repo.split("/").last)

      @gh.checkout_branch(dir, "hotfix/#{version}", sha)
      Versions.bump(dir, version)
      @gh.git_config_bot(dir)
      @gh.commit(dir, "chore: hotfix bump to #{version}", all: true)
      unless @gh.push(dir, "hotfix/#{version}", force: false)
        return Failure("failed to push hotfix/#{version}")
      end

      @gh.pr_create(
        repo: repo, base: "main", head: "hotfix/#{version}",
        title: "Hotfix #{version}",
        body: hotfix_pr_body(version)
      )

      Success(:ok)
    rescue Github::ApiError, Github::CommandError => e
      Failure("#{e.class}: #{e.message}")
    end

    def hotfix_pr_body(version)
      <<~BODY
        Hotfix release, based on the latest tagged release (patch bump).

        - Notes (edit here): https://github.com/xmtplabs/convos-releases/tree/main/releases/#{version}
        - Manifest: https://github.com/xmtplabs/convos-releases/blob/main/releases/#{version}/manifest.yml

        Every push to this branch uploads a fresh RC (TestFlight / Play internal). Merging stages the store submission.
      BODY
    end

    # persist_statuses: best-effort; "pending" is the conservative truthful
    # state if this push loses a race. Mirrors Cut#persist_statuses.
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
