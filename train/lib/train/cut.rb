# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "dry/monads"
require_relative "manifest"
require_relative "versions"
require_relative "config"
require_relative "notify"
require_relative "notes"
require_relative "github"

module Train
  # The weekly release-branch cut. Runs FROM a checkout of convos-releases
  # (cwd); Github wraps all subprocess calls and enforces dry-run.
  #
  # The pipeline is a chain of `yield step(...)` (Dry::Monads Do) that
  # short-circuits to the first Failure. Declining to cut (wrong
  # day/slot/skip-date) is Success(:skipped), an expected non-error outcome.
  class Cut
    include Dry::Monads[:result, :do]

    REPOS = %w[xmtplabs/convos-ios xmtplabs/convos-client].freeze

    def initialize(github:, releases_dir: Dir.pwd, out: $stdout, err: $stderr, notifier: nil)
      @gh = github
      @releases_dir = releases_dir
      @out = out
      @err = err
      @notifier = notifier || Notify.new(out: out, err: err)
    end

    # run: Success(:skipped | :dry_run | :cut) or Failure(message).
    def run(force: false, schedule: nil, date_override: nil)
      date = Config.today_et(date_override: date_override)

      decision = yield decide_slot(force: force, schedule: schedule, date: date)
      return Success(:skipped) if decision == :skipped

      yield guard_ref
      yield guard_synced_checkout
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

        # Persist per-repo statuses unconditionally (even if one repo failed)
        # before yielding, so a hard failure doesn't lose the other's status.
        result = ensure_all_repos(work: work, version: version, nxt: nxt, mfile: mfile, sha: sha)
        # Advance top-level status past "cut" only when every repo succeeded —
        # reconcile_in_flight treats "cut" as in-flight, so a partial failure
        # correctly stays there. Set before persist_statuses so one commit publishes both.
        Manifest.set_status(mfile, "branched") if result.success?
        persist_statuses(mdir, version)
        yield result

        @notifier.post_cut(version: version, kind: "release")
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

    # Same hazard as Hotfix#guard_synced_checkout: a locally-committed
    # manifest whose push failed must not survive into a retry, and a stale
    # checkout must not feed reconcile old ledger state.
    def guard_synced_checkout
      remote = @gh.ls_remote(@releases_dir, "refs/heads/main")
      return Success(:ok) if remote.empty?

      local = @gh.rev_parse(@releases_dir, "HEAD")
      return Success(:ok) if local == remote

      Failure("convos-releases checkout is not at origin/main (local #{local}, origin #{remote}) — reset/pull, then retry")
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

    # Scans durable state for an unfinished train. Today's still-status:cut
    # train is reconciled; an EARLIER-date one is a hard failure (a bump PR
    # never merged, or a cut never finished). Scans every manifest — glob
    # order isn't cut-date order, so a stale one appearing later must not slip through.
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

    # Once-per-version claim / reconcile. Returns the per-repo sha map for the
    # rest of the pipeline (freshly captured on init, recorded on reconcile).
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

    # The notes-seeding boundary is the previous train's cut date (tags don't
    # exist until promotion ships). Scans every manifest except the one being
    # cut and any "abandoned" ones. Returns nil (seed-notes' 7-day fallback)
    # only for the first-ever cut.
    def previous_cut_date(excluding:)
      dates = Dir.glob(File.join(@releases_dir, "releases", "*", "manifest.yml")).filter_map do |mf|
        next if File.dirname(mf) == File.join(@releases_dir, "releases", excluding)

        data = Manifest.read(mf)
        next if data["status"] == "abandoned"

        data["cut-date"]
      end
      dates.max
    end

    # Runs each repo's ensure steps independently, collecting per-repo
    # outcomes so one failure doesn't hide another's. bin/train prints the
    # returned Failure; don't print it here too.
    def ensure_all_repos(work:, version:, nxt:, mfile:, sha:)
      outcomes = REPOS.to_h { |repo| [repo, ensure_repo(work: work, repo: repo, version: version, nxt: nxt, sha: sha[repo])] }

      outcomes.each do |repo, result|
        Manifest.set_repo_status(mfile, repo: repo, status: "branched") if result.success?
      end

      failures = outcomes.select { |_repo, result| result.failure? }
      return Success(:ok) if failures.empty?

      Failure(failures.map { |repo, result| "#{repo}: #{result.failure}" }.join("; "))
    end

    # Only the release-branch check can fail this repo's ensure; bump-PR and
    # release-PR are best-effort (warn, don't fail). Their API/command errors
    # are rescued here so they can't abort the other repo's ensure.
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
      # Notes.format is the pure formatter; fetching PR JSON is Github's job
      # (stubbable in tests). This just wires them together.
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
