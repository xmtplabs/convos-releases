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
require_relative "ai_notes"

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

    def initialize(github:, releases_dir: Dir.pwd, out: $stdout, err: $stderr, notifier: nil, ai_notes: nil)
      @gh = github
      @releases_dir = releases_dir
      @out = out
      @err = err
      @notifier = notifier || Notify.new(out: out, err: err)
      @ai_notes = ai_notes || AiNotes.new(out: out, err: err)
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
        yield guard_ancestry(work)
        version = yield agree_on_version(captures)
        version = yield reconcile_in_flight(version, today)

        nxt = Versions.next_minor(version)
        @out.puts "Cutting release/#{version}; dev moves to #{nxt}"
        warn_on_version_drift(work: work, version: version)

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

        # Anchor durability comes BEFORE the ai_notes hand-off: the manifest
        # object is updated in memory and (best-effort) persisted to disk
        # first, so a later persist_statuses failure can never take down an
        # otherwise-completed cut, and ai_notes.request always sees the
        # thread whether or not the persist succeeded.
        thread = @notifier.post_cut(version: version, kind: "release")
        Manifest.set_announcement(mfile, **thread) if thread
        persist_statuses(mdir, version)
        @ai_notes.request(version: version, slack: thread)

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

    # A squashed back-merge leaves main with content dev never absorbed, and
    # every later release PR conflicts (the 2.3.0/2.5.0 incident). A conflict
    # probe, not an ancestor check: main's release merges are never in dev.
    def guard_ancestry(work)
      diverged = REPOS.select do |repo|
        dir = File.join(work, repo.split("/").last)
        @gh.merge_conflicts?(dir, "origin/dev", "origin/main")
      end
      return Success(:ok) if diverged.empty?

      messages = diverged.map do |repo|
        "#{repo}: merging main into dev would conflict — a back-merge was skipped or squash-merged; true-merge main into dev, then retry the cut"
      end
      Failure(messages.join("; "))
    rescue Github::CommandError => e
      Failure("could not evaluate main/dev mergeability: #{e.message}")
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

    # Cut-time canary for the graph shape that produced the 2.6.0 incident: a
    # merge-base(main, dev) that already reads a DIFFERENT version than main
    # means main is the side that "changed" the version line, so any three-way
    # merge based there resolves to MAIN's version, silently.
    #
    # Warn, don't fail. ensure_release_branch now makes release/X contain
    # main's tip, which moves the release->main merge's base to main's own tip
    # and takes this condition out of that decision entirely — so it is a
    # diagnostic, not a verdict, and failing the weekly cut on a signal the
    # cut itself has already defused would trade a silent bug for a loud
    # outage. The gates that actually protect the store artifact
    # (Promote#assert_trees_match, Promote#assert_rc_version) stay hard, and
    # they are what caught 2.6.0 with nothing yet mutated.
    #
    # Per repo, and never fatal: an unreadable blob degrades to a warning
    # about the canary itself rather than taking down a cut over a diagnostic.
    def warn_on_version_drift(work:, version:)
      REPOS.each do |repo|
        dir = File.join(work, repo.split("/").last)
        base = @gh.merge_base(dir, "origin/main", "origin/dev")
        layout, = Versions.layout_for(dir)
        path = Versions::REL_PATHS.fetch(layout)
        base_version = version_at(dir: dir, rev: base, layout: layout, path: path)
        main_version = version_at(dir: dir, rev: "origin/main", layout: layout, path: path)
        next if base_version == main_version

        loud_warning(
          "#{repo}: version drift — merge-base(main, dev) #{base} reads #{base_version} but main reads " \
          "#{main_version}. That is the 2.6.0 shape: in any three-way merge based on #{base}, main is the " \
          "only side that changed the version line, so the merge takes #{main_version}. release/#{version} " \
          "is cut as a merge of dev AND main, whose base is main's own tip, which neutralizes it — but if " \
          "the release PR's merge commit reads anything other than #{version}, STOP before tagging."
        )
      rescue Github::CommandError, Versions::Error => e
        loud_warning("#{repo}: could not evaluate the merge-base version drift canary: #{e.message}")
      end
    end

    # The version in the blob at `rev`, not in the worktree — the canary is
    # about what two COMMITS say, which is what a merge compares.
    def version_at(dir:, rev:, layout:, path:)
      Versions.read_content(layout, @gh.show_file(dir, rev, path), label: "#{rev}:#{path}")
    end

    def print_dry_run_plan(version, sha, nxt)
      @out.puts "DRY RUN — plan:"
      REPOS.each do |repo|
        @out.puts "  #{repo}: branch release/#{version} = merge(dev #{sha[repo]}, main) @ version #{version}; " \
                  "bump PR -> #{nxt}; release PR -> main"
      end
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
      submission << "#{Notes::REVIEWER_PLACEHOLDER}\n\n"
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

    # release/X is cut as a MERGE of dev's tip AND main's tip, with the version
    # file re-asserted to X in that same commit.
    #
    # Why (the 2026-08-28 2.6.0 incident): git merges compare CONTENT against
    # the merge base, not commits. merge-base(main, release/2.6.0) was a DEV
    # commit that already read 2.6.0; main had since changed that line to
    # 2.5.0 (the 2.5.0 release's restore commits, which reached main through
    # that release's merge); release/2.6.0 never touched it, so it was
    # UNCHANGED relative to the base. A three-way merge takes the side that
    # changed — so the release PR's merge commit came out stamped 2.5.0 while
    # the RC'd tip and the uploaded TestFlight build said 2.6.0. No conflict,
    # no signal. Promote#assert_trees_match caught it before anything was
    # tagged, but the release had to be repaired by hand. The arming condition
    # is exactly version_at(merge-base(main, dev)) != version_at(main), which
    # recurs every time a release branch merges dev in after the post-cut bump
    # and then restores its own version — i.e. every time the discipline is
    # followed correctly.
    #
    # Making release/X contain main's tip resets that base permanently: the
    # base of the later release->main merge becomes main's own tip, so main is
    # UNCHANGED and release/X (version X) is the only side that changed. The
    # merge can only resolve to X — and, main being an ancestor, its tree is
    # exactly the RC'd tip's tree, which is the invariant assert_trees_match
    # exists to check. Self-sustaining, too: later dev merges into release/X
    # only move the base along dev's line, and the next cut merges main in
    # again. See test/release_branch_merge_test.rb for the property on real git.
    #
    # NOT an explicit version commit on release/X at cut time — that idea has
    # been ruled out twice: at cut the release version already equals dev's,
    # so the commit is empty, and an empty commit changes no content for a
    # three-way merge to see.
    def ensure_release_branch(dir:, repo:, version:, sha:)
      existing = @gh.ls_remote(dir, "refs/heads/release/#{version}")
      unless existing.empty?
        return converge_release_branch(dir: dir, repo: repo, version: version, sha: sha, existing: existing)
      end

      tip = yield build_release_tip(dir: dir, repo: repo, version: version, sha: sha)
      unless @gh.push(dir, "#{tip}:refs/heads/release/#{version}")
        return Failure("#{repo}: failed to push release/#{version}")
      end

      @out.puts "#{repo}: created release/#{version} @ #{tip} (dev #{sha} merged with main)"
      Success(:ok)
    end

    # Builds the release tip locally and returns its sha: detach at dev's cut
    # sha (so dev is the FIRST parent), merge main, re-assert the version,
    # commit. ONE commit, and the caller makes ONE push — creating the branch
    # still triggers exactly one RC upload, as it always did.
    def build_release_tip(dir:, repo:, version:, sha:)
      main_sha = @gh.rev_parse(dir, "origin/main")
      @gh.checkout(dir, sha)

      unless @gh.merge_no_commit(dir, main_sha)
        @gh.merge_abort(dir)
        return Failure("#{repo}: merging main (#{main_sha}) into dev (#{sha}) for release/#{version} conflicted — " \
                       "guard_ancestry probes exactly this merge before the cut claims anything, so a conflict " \
                       "here means main moved underneath it; true-merge main into dev, then re-dispatch the cut")
      end

      # dev already reads `version`, but main's side of the merge carries the
      # PREVIOUS one, and whichever side changed the line wins — so assert it
      # rather than assume. A no-op write when the merge left X in place.
      Versions.bump(dir, version)
      @gh.git_config_bot(dir)
      # `all: true` sweeps up both the staged merge and the version rewrite, so
      # the merge commit IS the version-asserting commit — and it is authored
      # by the bot, which keeps Promote's back-merge gate ignoring it. A false
      # return ("nothing to commit") means main was already merged AND the
      # version already read X; the tip is then just `sha`, still correct.
      @gh.commit(dir, "train: cut release/#{version} (merge main; version #{version})", all: true)

      Success(@gh.rev_parse(dir))
    rescue Versions::Error => e
      @gh.merge_abort(dir)
      Failure("#{repo}: could not re-assert version #{version} on the release/#{version} tip: #{e.message}")
    rescue Github::CommandError => e
      @gh.merge_abort(dir)
      Failure("#{repo}: could not build the release/#{version} tip: #{e.message}")
    end

    # An existing release/X is CONVERGED, not compared for equality. The tip is
    # a merge commit now, and this run would rebuild it with a different sha
    # (merge commits carry timestamps), so `existing != sha` is no longer
    # evidence of anything — while re-dispatching a cut still has to converge,
    # since the whole cut path is ensure-state.
    #
    # What the equality check was really protecting is kept: a branch that does
    # NOT contain dev's cut sha predates the cut (a stale manual release/X),
    # and is refused rather than pushed over. Our own tip contains it (it
    # merges it), and so does a branch that has since advanced with RC fixes or
    # a dev merge — which is exactly the set that should converge.
    def converge_release_branch(dir:, repo:, version:, sha:, existing:)
      if existing == sha
        @out.puts "#{repo}: release/#{version} already correct"
        return Success(:ok)
      end

      # An earlier run pushed that tip from a DIFFERENT clone, so this one may
      # not hold the object yet — fetch before asking git about ancestry (the
      # same reason Promote fetches before commit_authors).
      @gh.fetch(dir, existing)
      if @gh.ancestor?(dir, sha, existing)
        @out.puts "#{repo}: release/#{version} already exists at #{existing} and contains dev #{sha}"
        return Success(:ok)
      end

      Failure("#{repo} release/#{version} exists at #{existing}, which does not contain dev's cut sha #{sha} — " \
              "a branch with that name predates the cut (e.g. a stale manual release branch); confirm it's " \
              "stale with its owner, delete it, then re-dispatch")
    rescue Github::CommandError => e
      Failure("#{repo}: could not check the existing release/#{version} at #{existing}: #{e.message}")
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
    # state if this push loses a race. `run` calls this twice: once right
    # after ensure_all_repos (so a hard failure doesn't lose a partial
    # success), and again after set_announcement (dirty?-gated, so a no-op
    # unless that wrote a fresh thread anchor) so that anchor ships in the
    # same best-effort commit rather than a separate push. The whole body is
    # rescued — a raising add/commit must never fail an otherwise-completed
    # cut; the anchor already lives in the in-memory manifest either way.
    def persist_statuses(mdir, version)
      return unless @gh.dirty?(@releases_dir, mdir)

      @gh.add(@releases_dir, mdir)
      @gh.commit(@releases_dir, "train: #{version} repo statuses")
      ok = @gh.push(@releases_dir, "HEAD:main")
      reset_stranded_checkout unless ok
    rescue Github::CommandError, Github::ApiError => e
      loud_warning("status/anchor persist failed: #{e.message}")
    end

    # A failed push leaves @releases_dir sitting one commit ahead of
    # origin/main — left alone, the NEXT run's guard_synced_checkout would
    # hard-fail until a human resets it. Remote main is the source of truth,
    # so fetch it and reset the local checkout to FETCH_HEAD: the push failed
    # because origin advanced past what this clone pushed from, so the sha
    # ls_remote reports may not exist locally yet — resetting straight to it
    # would fail and leave the checkout wedged. The whole recovery is
    # best-effort (a failure here is still just a warning, not a Failure).
    def reset_stranded_checkout
      loud_warning("status push failed; manifest remains pending")
      remote = @gh.ls_remote(@releases_dir, "refs/heads/main")
      return if remote.empty?

      @gh.fetch(@releases_dir, "main")
      @gh.reset_hard(@releases_dir, "FETCH_HEAD")
    rescue Github::CommandError, Github::ApiError => e
      loud_warning("stranded-checkout reset failed: #{e.message}")
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
