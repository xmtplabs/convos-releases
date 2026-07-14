# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "dry/monads"
require_relative "manifest"
require_relative "versions"
require_relative "config"
require_relative "notes"

module Train
  # Ports the release-cut.yml "Cut" step. Runs FROM a checkout of
  # convos-releases (cwd); Github wraps all git/gh subprocess calls and
  # centrally enforces dry-run.
  #
  # The pipeline is a chain of Success/Failure steps (Dry::Monads Do
  # notation): `yield step(...)` short-circuits to the first Failure, so
  # each step can assume everything before it succeeded. Declining to cut
  # (wrong day/slot/skip-date) is Success(:skipped), not a Failure — it's
  # an expected, non-error outcome. bin/train is the only place that maps
  # the final Result to an exit code.
  class Cut
    include Dry::Monads[:result, :do]

    REPOS = %w[xmtplabs/convos-ios xmtplabs/convos-client].freeze

    def initialize(github:, releases_dir: Dir.pwd, out: $stdout, err: $stderr)
      @gh = github
      @releases_dir = releases_dir
      @out = out
      @err = err
    end

    # run: Success(:skipped | :dry_run | :cut) or Failure(message).
    def run(force: false, schedule: nil, date_override: nil)
      date = Config.today_et(date_override: date_override)

      decision = yield decide_slot(force: force, schedule: schedule, date: date)
      return Success(:skipped) if decision == :skipped

      yield guard_ref
      set_bot_remote

      today = date.strftime("%F")
      work = Dir.mktmpdir("train-cut-")
      begin
        sha, ver = capture_repos(work)
        version = yield agree_on_version(ver)
        version = yield reconcile_in_flight(version, today)

        maj, min, = version.split(".").map(&:to_i)
        nxt = "#{maj}.#{min + 1}.0"
        @out.puts "Cutting release/#{version}; dev moves to #{nxt}"

        if @gh.dry_run
          print_dry_run_plan(version, sha)
          return Success(:dry_run)
        end

        mdir = File.join(@releases_dir, "releases", version)
        mfile = File.join(mdir, "manifest.yml")
        sha = yield init_or_reconcile_manifest(mfile: mfile, mdir: mdir, version: version, today: today, sha: sha, work: work)

        yield ensure_all_repos(work: work, version: version, nxt: nxt, mfile: mfile, sha: sha)
        persist_statuses(mdir, version)

        Success(:cut)
      ensure
        FileUtils.remove_entry(work) if Dir.exist?(work)
      end
    end

    private

    def decide_slot(force:, schedule:, date:)
      config = Config.load(File.join(@releases_dir, "release-config.yml"))
      decision = Config.slot_decision(force: force, schedule: schedule, date: date, config: config)
      unless decision.go
        @out.puts decision.reason
        return Success(:skipped)
      end

      Success(:go)
    end

    def guard_ref
      ref = ENV["GITHUB_REF_NAME"]
      return Success(:ok) unless ref && ref != "main"

      Failure("release-cut must run from main (got #{ref})")
    end

    def set_bot_remote
      token = ENV["GH_TOKEN"]
      return if token.to_s.empty?

      @gh.set_remote_url(@releases_dir, "https://x-access-token:#{token}@github.com/xmtplabs/convos-releases.git")
    end

    # capture_repos: one SHA per repo, version read AT that SHA.
    def capture_repos(work)
      sha = {}
      ver = {}
      REPOS.each do |repo|
        dir = File.join(work, repo.split("/").last)
        @gh.clone("https://x-access-token:#{ENV["GH_TOKEN"]}@github.com/#{repo}.git", dir, filter: "blob:none")
        @gh.checkout(dir, "origin/dev")
        sha[repo] = @gh.rev_parse(dir)
        ver[repo] = Versions.read(dir)
        @out.puts "#{repo} dev=#{sha[repo]} version=#{ver[repo]}"
      end
      [sha, ver]
    end

    def agree_on_version(ver)
      first = ver.values.first
      ver.each do |_repo, v|
        next if v == first

        return Failure("repos disagree on version (#{v} vs #{first}) — resolve stray bump PR first")
      end
      Success(first)
    end

    # reconcile_in_flight: version arithmetic can't find the previous train
    # (versions don't end in .0), so scan the durable state instead. A
    # train cut TODAY and still status:cut is reconciled; one from an
    # EARLIER date still status:cut means a bump PR never merged or a cut
    # never finished — fail loud rather than silently cutting on top of it.
    def reconcile_in_flight(version, today)
      Dir.glob(File.join(@releases_dir, "releases", "*", "manifest.yml")).sort.each do |mf|
        next unless Manifest.get(mf, "status") == "cut"

        mdate = Manifest.get(mf, "cut-date")
        mver = Manifest.get(mf, "version")
        if mdate == today
          @out.puts "In-flight train #{mver} (cut today, still status:cut) — reconciling it instead of cutting #{version}"
          return Success(mver)
        end

        return Failure("train #{mver} cut #{mdate} is still status:cut — resolve it (bump PRs merged? cut finished?) before cutting a new train")
      end
      Success(version)
    end

    def print_dry_run_plan(version, sha)
      @out.puts "DRY RUN — plan:"
      REPOS.each { |repo| @out.puts "  #{repo}: branch release/#{version} @ #{sha[repo]}; bump PR -> next; release PR -> main" }
      @out.puts "  convos-releases: releases/#{version}/{manifest.yml,ios.md,android.md,submission-notes.md}"
    end

    # init_or_reconcile_manifest: once-per-version claim / reconcile mode.
    # Returns the per-repo sha map to use for the rest of the pipeline
    # (freshly captured on init, recorded-in-manifest on reconcile).
    def init_or_reconcile_manifest(mfile:, mdir:, version:, today:, sha:, work:)
      if File.exist?(mfile)
        @out.puts "Manifest exists — reconcile mode."
        recorded = REPOS.to_h { |repo| [repo, Manifest.get(mfile, "repos", repo, "source-sha")] }
        return Success(recorded)
      end

      FileUtils.mkdir_p(mdir)
      Manifest.init(mfile, version: version, kind: "release", cut_date: today, repos: sha.slice(*REPOS))
      write_seed_notes(mdir: mdir, version: version, work: work)

      @gh.git_config_bot(@releases_dir)
      @gh.add(@releases_dir, mdir)
      @gh.commit(@releases_dir, "train: cut #{version}")
      @gh.push(@releases_dir, "HEAD:main")

      Success(sha)
    end

    def write_seed_notes(mdir:, version:, work:)
      last_ios_tag = @gh.tags(File.join(work, "convos-ios"), "v*").first
      last_cli_tag = @gh.tags(File.join(work, "convos-client"), "v*").first
      since_ios = last_ios_tag ? @gh.commit_date(File.join(work, "convos-ios"), last_ios_tag) : ""
      since_cli = last_cli_tag ? @gh.commit_date(File.join(work, "convos-client"), last_cli_tag) : ""

      File.write(File.join(mdir, "ios.md"), seed_notes("xmtplabs/convos-ios", since_ios))
      android_notes = seed_notes("xmtplabs/convos-client", since_cli)
      File.write(File.join(mdir, "android.md"), android_notes)
      submission = +"# Submission notes for #{version}\n\n"
      submission << "_For app reviewers: summarize user-visible changes, test-account hints._\n\n"
      submission << android_notes
      File.write(File.join(mdir, "submission-notes.md"), submission)
    end

    # ensure_all_repos: runs each repo's ensure steps independently and
    # collects Success/Failure per repo, so a failure on one repo (e.g. a
    # release-branch mismatch) doesn't hide the other repo's outcome — both
    # ensures run before the combined Failure is returned. The caller (bin/
    # train) prints the returned Failure message; this doesn't print here
    # too.
    def ensure_all_repos(work:, version:, nxt:, mfile:, sha:)
      outcomes = REPOS.to_h { |repo| [repo, ensure_repo(work: work, repo: repo, version: version, nxt: nxt, sha: sha[repo])] }

      outcomes.each do |repo, result|
        Manifest.set_repo_status(mfile, repo: repo, status: "branched") if result.success?
      end

      failures = outcomes.select { |_repo, result| result.failure? }
      return Success(:ok) if failures.empty?

      Failure(failures.map { |repo, result| "#{repo}: #{result.failure}" }.join("; "))
    end

    # ensure_repo: the release-branch check is the only step that can fail
    # this repo's ensure; bump-PR and release-PR steps are best-effort
    # (warn, don't fail) so one repo's flaky auto-merge doesn't block the
    # other repo's progress.
    def ensure_repo(work:, repo:, version:, nxt:, sha:)
      dir = File.join(work, repo.split("/").last)

      yield ensure_release_branch(dir: dir, repo: repo, version: version, sha: sha)
      ensure_bump_pr(dir: dir, repo: repo, nxt: nxt, version: version, sha: sha)
      ensure_release_pr(repo: repo, version: version)

      Success(:ok)
    end

    def ensure_release_branch(dir:, repo:, version:, sha:)
      existing = @gh.ls_remote(dir, "refs/heads/release/#{version}")
      if existing.empty?
        @gh.push(dir, "#{sha}:refs/heads/release/#{version}")
        @out.puts "#{repo}: created release/#{version} @ #{sha}"
      elsif existing != sha
        return Failure("#{repo} release/#{version} exists at #{existing}, expected #{sha}")
      else
        @out.puts "#{repo}: release/#{version} already correct"
      end
      Success(:ok)
    end

    # ensure_bump_pr: state: all — in reconcile mode the bump PR may
    # already be MERGED; recreating it would fail with "no commits between
    # dev and head".
    def ensure_bump_pr(dir:, repo:, nxt:, version:, sha:)
      bump_head = "bot/bump-#{nxt}"
      existing_bump = @gh.pr_list(repo: repo, head: bump_head, state: "all")
      if existing_bump.empty?
        @gh.checkout_branch(dir, bump_head, sha)
        Versions.bump(dir, nxt)
        @gh.commit(dir, "chore: bump version to #{nxt} after #{version} cut", all: true)
        @gh.push(dir, bump_head, force: true)
        @gh.pr_create(
          repo: repo, base: "dev", head: bump_head,
          title: "Bump version to #{nxt}",
          body: "Automated post-cut bump: release/#{version} departed; dev now builds #{nxt}. Part of the release train."
        )
        ok = @gh.pr_merge_auto(repo: repo, head_or_number: bump_head)
        loud_warning("auto-merge not enabled on #{repo}?") unless ok
      else
        @out.puts "#{repo}: bump PR exists"
        # Re-arm auto-merge: a transient failure at creation time must not
        # leave the bump PR unmergeable forever.
        open_bump = @gh.pr_list(repo: repo, head: bump_head, state: "open").first
        if open_bump
          ok = @gh.pr_merge_auto(repo: repo, head_or_number: open_bump.fetch("number"))
          loud_warning("auto-merge re-arm failed on #{repo}##{open_bump.fetch("number")}") unless ok
        end
      end
    end

    def ensure_release_pr(repo:, version:)
      existing_release_pr = @gh.pr_list(repo: repo, head: "release/#{version}", base: "main", state: "open")
      if existing_release_pr.empty?
        @gh.pr_create(
          repo: repo, base: "main", head: "release/#{version}",
          title: "Release #{version}",
          body: release_pr_body(version)
        )
      else
        @out.puts "#{repo}: release PR exists"
      end
    end

    # persist_statuses: best-effort; "pending" is the conservative truthful
    # state if this push loses a race.
    def persist_statuses(mdir, version)
      return unless @gh.dirty?(@releases_dir, mdir)

      @gh.add(@releases_dir, mdir)
      @gh.commit(@releases_dir, "train: #{version} repo statuses")
      ok = @gh.push(@releases_dir, "HEAD:main")
      loud_warning("status push failed; manifest remains pending") unless ok
    end

    def seed_notes(repo, since)
      # cut.rb never shells to `gh` itself for notes — Notes.format is the
      # pure formatter; fetching PR JSON is a Github responsibility so it
      # can be stubbed in tests. seed_notes here just wires them together.
      prs = @gh.merged_prs_since(repo, since.to_s.empty? ? Notes.default_since : since)
      Notes.format(prs)
    end

    def release_pr_body(version)
      <<~BODY
        Weekly release train.

        - Notes (edit here): https://github.com/xmtplabs/convos-releases/tree/main/releases/#{version}
        - Manifest: https://github.com/xmtplabs/convos-releases/blob/main/releases/#{version}/manifest.yml

        Every push to this branch uploads a fresh RC (TestFlight / Play internal). Merging stages the store submission.
      BODY
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
