# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "dry/monads"
require_relative "manifest"
require_relative "versions"
require_relative "config"
require_relative "notes"
require_relative "github"

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
        captures = capture_repos(work)
        version = yield agree_on_version(captures)
        version = yield reconcile_in_flight(version, today)

        maj, min, = version.split(".").map(&:to_i)
        nxt = "#{maj}.#{min + 1}.0"
        @out.puts "Cutting release/#{version}; dev moves to #{nxt}"

        sha = captures.transform_values { |c| c[:sha] }

        if @gh.dry_run
          print_dry_run_plan(version, sha, nxt)
          return Success(:dry_run)
        end

        mdir = File.join(@releases_dir, "releases", version)
        mfile = File.join(mdir, "manifest.yml")
        sha = yield init_or_reconcile_manifest(mfile: mfile, mdir: mdir, version: version, today: today, sha: sha)

        # Persist whatever statuses ensure_all_repos wrote to the manifest
        # (e.g. one repo's "branched") UNCONDITIONALLY — even when the other
        # repo's ensure failed — before yielding the result, so a hard
        # failure on one repo doesn't lose the successful repo's committed
        # status. `yield` below still short-circuits to the Failure after
        # the commit/push has happened.
        result = ensure_all_repos(work: work, version: version, nxt: nxt, mfile: mfile, sha: sha)
        # Advance the top-level manifest status past "cut" ONLY when every
        # repo succeeded — reconcile_in_flight treats status:"cut" as
        # in-flight, so leaving it at "cut" after a partial failure is
        # correct (still in-flight); advancing it here, before
        # persist_statuses, ensures the same commit publishes both.
        Manifest.set_status(mfile, "branched") if result.success?
        persist_statuses(mdir, version)
        yield result

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

    # capture_repos: one SHA + version per repo, version read AT that SHA.
    def capture_repos(work)
      REPOS.to_h do |repo|
        dir = File.join(work, repo.split("/").last)
        @gh.clone("https://x-access-token:#{ENV["GH_TOKEN"]}@github.com/#{repo}.git", dir, filter: "blob:none")
        @gh.checkout(dir, "origin/dev")
        repo_sha = @gh.rev_parse(dir)
        repo_ver = Versions.read(dir)
        @out.puts "#{repo} dev=#{repo_sha} version=#{repo_ver}"
        [repo, { sha: repo_sha, version: repo_ver }]
      end
    end

    def agree_on_version(captures)
      first = captures.values.first[:version]
      captures.each do |_repo, c|
        next if c[:version] == first

        return Failure("repos disagree on version (#{c[:version]} vs #{first}) — resolve stray bump PR first")
      end
      Success(first)
    end

    # reconcile_in_flight: version arithmetic can't find the previous train
    # (versions don't end in .0), so scan the durable state instead. A
    # train cut TODAY and still status:cut is reconciled; one from an
    # EARLIER date still status:cut means a bump PR never merged or a cut
    # never finished — fail loud rather than silently cutting on top of it.
    #
    # Scans EVERY manifest rather than returning on the first same-day
    # status:cut hit — glob order isn't cut-date order, so a stale
    # (older-date) status:cut train appearing later in glob order must still
    # be caught rather than silently skipped.
    def reconcile_in_flight(version, today)
      in_flight = nil
      Dir.glob(File.join(@releases_dir, "releases", "*", "manifest.yml")).sort.each do |mf|
        data = Manifest.read(mf)
        next unless data["status"] == "cut"

        mdate = data["cut-date"]
        mver = data["version"]
        if mdate == today
          in_flight ||= mver
          next
        end

        return Failure("train #{mver} cut #{mdate} is still status:cut — resolve it (bump PRs merged? cut finished?) before cutting a new train")
      end

      if in_flight
        @out.puts "In-flight train #{in_flight} (cut today, still status:cut) — reconciling it instead of cutting #{version}"
      end
      Success(in_flight || version)
    end

    def print_dry_run_plan(version, sha, nxt)
      @out.puts "DRY RUN — plan:"
      REPOS.each { |repo| @out.puts "  #{repo}: branch release/#{version} @ #{sha[repo]}; bump PR -> #{nxt}; release PR -> main" }
      @out.puts "  convos-releases: releases/#{version}/{manifest.yml,ios.md,android.md,submission-notes.md}"
    end

    # init_or_reconcile_manifest: once-per-version claim / reconcile mode.
    # Returns the per-repo sha map to use for the rest of the pipeline
    # (freshly captured on init, recorded-in-manifest on reconcile).
    def init_or_reconcile_manifest(mfile:, mdir:, version:, today:, sha:)
      if File.exist?(mfile)
        @out.puts "Manifest exists — reconcile mode."
        data = Manifest.read(mfile)
        recorded = REPOS.to_h { |repo| [repo, data.dig("repos", repo, "source-sha")] }
        return Success(recorded)
      end

      FileUtils.mkdir_p(mdir)
      Manifest.init(mfile, version: version, kind: "release", cut_date: today, repos: sha.slice(*REPOS))
      write_seed_notes(mdir: mdir, version: version)

      @gh.git_config_bot(@releases_dir)
      @gh.add(@releases_dir, mdir)
      @gh.commit(@releases_dir, "train: cut #{version}")
      unless @gh.push(@releases_dir, "HEAD:main")
        return Failure("manifest push to convos-releases main failed (non-fast-forward? retry the cut)")
      end

      Success(sha)
    end

    def write_seed_notes(mdir:, version:)
      since = previous_cut_date(excluding: version)

      File.write(File.join(mdir, "ios.md"), seed_notes("xmtplabs/convos-ios", since))
      android_notes = seed_notes("xmtplabs/convos-client", since)
      File.write(File.join(mdir, "android.md"), android_notes)
      submission = +"# Submission notes for #{version}\n\n"
      submission << "_For app reviewers: summarize user-visible changes, test-account hints._\n\n"
      submission << android_notes
      File.write(File.join(mdir, "submission-notes.md"), submission)
    end

    # previous_cut_date: the notes-seeding boundary for BOTH repos is the
    # previous train's cut date, not a tag/commit lookup — tags don't exist
    # until Phase-2 promotion ships, so deriving `since` from them would
    # always fall back to seed-notes' 7-day window and a skipped week would
    # silently lose changelog entries. Scans every manifest EXCEPT the one
    # for the version currently being cut (it was just written by
    # Manifest.init, moments before this runs, and would otherwise win as
    # its own "most recent" prior manifest). Manifests with top-level
    # status "abandoned" are excluded from consideration — an abandoned
    # train's cut-date isn't a real boundary. Returns nil (seed-notes' own
    # 7-day fallback applies) when no qualifying prior manifest exists —
    # i.e. only for the first-ever cut.
    def previous_cut_date(excluding:)
      dates = Dir.glob(File.join(@releases_dir, "releases", "*", "manifest.yml")).filter_map do |mf|
        next if File.dirname(mf) == File.join(@releases_dir, "releases", excluding)

        data = Manifest.read(mf)
        next if data["status"] == "abandoned"

        data["cut-date"]
      end
      dates.max
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
    # other repo's progress. Github::ApiError/CommandError raised inside
    # either best-effort step must not propagate — that would abort
    # ensure_all_repos entirely and skip the OTHER repo's ensure_repo call,
    # contradicting the best-effort contract documented above.
    def ensure_repo(work:, repo:, version:, nxt:, sha:)
      dir = File.join(work, repo.split("/").last)

      yield ensure_release_branch(dir: dir, repo: repo, version: version, sha: sha)

      begin
        ensure_bump_pr(dir: dir, repo: repo, nxt: nxt, version: version, sha: sha)
      rescue Github::ApiError, Github::CommandError => e
        loud_warning("#{repo}: bump PR step failed: #{e.message}")
      end

      begin
        ensure_release_pr(repo: repo, version: version)
      rescue Github::ApiError, Github::CommandError => e
        loud_warning("#{repo}: release PR step failed: #{e.message}")
      end

      Success(:ok)
    end

    def ensure_release_branch(dir:, repo:, version:, sha:)
      existing = @gh.ls_remote(dir, "refs/heads/release/#{version}")
      if existing.empty?
        unless @gh.push(dir, "#{sha}:refs/heads/release/#{version}")
          return Failure("#{repo}: failed to push release/#{version}")
        end
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
        # fresh clone: no committer identity until we set the bot's
        @gh.git_config_bot(dir)
        @gh.commit(dir, "chore: bump version to #{nxt} after #{version} cut", all: true)
        unless @gh.push(dir, bump_head, force: true)
          loud_warning("#{repo}: bump branch push failed; skipping bump PR")
          return
        end
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
