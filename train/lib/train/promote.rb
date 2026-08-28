# frozen_string_literal: true

require "fileutils"
require "uri"
require "dry/monads"
require_relative "manifest"
require_relative "state_writer"
require_relative "github"
require_relative "versions"
require_relative "notes"
require_relative "store_notes"

module Train
  # The "Promote" step: given a merged release PR (merge_sha) and the branch
  # tip it merged from (head_sha), verify the RC uploaded from head_sha, tag
  # the merge commit, and stage release notes for store submission. Runs FROM
  # the app-repo checkout (cwd); convos-releases is cloned fresh internally.
  class Promote
    include Dry::Monads[:result, :do]

    def initialize(github:, out: $stdout)
      @gh = github
      @out = out
      @writer = StateWriter.new(github: github, out: out)
    end

    # prepare: returns a Result — Success(true) (including under dry-run)
    # or Failure(message).
    def prepare(repo:, version:, merge_sha:, head_sha:, app_dir: Dir.pwd)
      yield assert_version_format(version)

      @gh.with_releases_clone("train-promote-") do |dir|
        mfile = File.join(dir, "releases", version, "manifest.yml")
        next Failure("no manifest for #{version}") unless File.exist?(mfile)

        manifest_data = Manifest.read(mfile)
        rc = yield find_rc_entry(manifest_data, repo: repo, head_sha: head_sha)
        key, value = rc
        yield assert_key_matches_platform(repo: repo, key: key)

        yield assert_trees_match(app_dir: app_dir, merge_sha: merge_sha, head_sha: head_sha)
        yield assert_rc_version(app_dir: app_dir, version: version, head_sha: head_sha)

        # Notes staged (and checked) BEFORE the tag push — unedited
        # placeholder notes should stop promotion while nothing has been
        # mutated yet, not after the tag is already claimed.
        notes_dir = File.join(app_dir, ".train-promote")
        notes_sha = copy_notes(clone_dir: dir, version: version, notes_dir: notes_dir)
        yield assert_notes_present(repo: repo, version: version, notes_dir: notes_dir)
        yield assert_notes_edited(repo: repo, version: version, notes_dir: notes_dir)
        yield assert_notes_fit(repo: repo, version: version, notes_dir: notes_dir)

        yield ensure_tag(app_dir: app_dir, version: version, merge_sha: merge_sha)

        emit_outputs(
          key: key, value: value, version: version, notes_sha: notes_sha, notes_dir: notes_dir
        )

        Success(true)
      end
    end

    # The "Record promotion" step: for a hotfix, opens the back-merge PR FIRST
    # (hard-gated), then writes the promoted block to the manifest, ensures a
    # GitHub Release on the APP repo, and (with pr_number) posts a summary
    # comment. "kind" is read from the manifest, never trusted from a flag.
    def record(repo:, version:, tag:, key:, value:, notes_sha:, run_url:, pr_number: nil, app_dir: Dir.pwd)
      # Pre-validate BEFORE any I/O so a bad id fails fast as a Result, not a
      # Manifest::Error from inside the StateWriter loop.
      yield assert_version_format(version)

      # The tag is always v<version> — a mismatched pair on a manual run would
      # promote one version but stage a Release for another.
      unless tag == Versions.tag(version)
        return Failure("record: --tag must be v#{version}, got '#{tag}'")
      end

      value_str = value.to_s
      unless value_str.match?(Manifest::POSITIVE_INT_RE)
        return Failure("record: --value must be a positive integer, got '#{value_str}'")
      end

      # Same key<->platform guard as prepare, for direct manual runs.
      yield assert_key_matches_platform(repo: repo, key: key)

      # Reading kind here also fails a nonexistent manifest before any
      # back-merge PR is opened.
      kind = yield read_manifest_kind(version)

      # Back-merge BEFORE the manifest write: a hard failure here must leave
      # the manifest untouched rather than record a promotion whose back-merge
      # never happened. Rerun cases are tolerated (see the method).
      if kind == "hotfix"
        yield open_back_merge_pr(repo: repo, version: version, kind: kind, app_dir: app_dir)
      elsif kind == "release"
        yield ensure_release_back_merge(repo: repo, version: version, app_dir: app_dir)
      end

      yield record_promotion(repo: repo, version: version, key: key, value: value_str, tag: tag, notes_sha: notes_sha, run_url: run_url)

      ensure_release(repo: repo, tag: tag, app_dir: app_dir)

      post_pr_comment(repo: repo, tag: tag, version: version, pr_number: pr_number) if pr_number

      Success(true)
    end

    private

    # version comes from a caller-resolved branch name and is used in paths and
    # refs — reject anything that isn't X.Y.Z first.
    def assert_version_format(version)
      return Success(:ok) if Versions.valid?(version)

      Failure("version must look like X.Y.Z, got '#{version}'")
    end

    # The version's manifest "kind" via a fresh read-only depth-1 clone —
    # record decides the back-merge from the manifest, never caller input.
    def read_manifest_kind(version)
      @gh.with_releases_clone("train-record-") do |dir|
        mfile = File.join(dir, "releases", version, "manifest.yml")
        next Failure("no manifest for #{version}") unless File.exist?(mfile)

        Success(Manifest.read(mfile).fetch("kind"))
      end
    end

    # The StateWriter-backed write of the promoted block. An unchanged
    # (already-recorded) block is still a successful no-op write.
    def record_promotion(repo:, version:, key:, value:, tag:, notes_sha:, run_url:)
      @writer.write(message: "train: promoted #{repo}@#{tag}") do |dir|
        mfile = File.join(dir, "releases", version, "manifest.yml")
        next Failure("no manifest for #{version}") unless File.exist?(mfile)

        Manifest.record_promotion(mfile, repo: repo, key: key, value: value, tag: tag, notes_sha: notes_sha, run: run_url)
        Success(true)
      end
    end

    # Back-merge pr_create errors (case-insensitive) that mean "already
    # happened": the PR was opened on a prior run, or dev is already level.
    TOLERATED_BACK_MERGE_ERRORS = [
      "a pull request already exists",
      "no commits between"
    ].freeze


    # Hard-gated: a genuine API failure returns Failure and aborts record
    # before the manifest is written; only the two tolerated errors above
    # become a Success note. kind is "hotfix" or "release" — same machinery,
    # different source branch.
    #
    # The PR head is a dedicated backmerge/<version> branch at the source
    # branch's tip, NEVER release/<v> or hotfix/<v> themselves: the app
    # repos' RC-upload workflows run on every push to those branches, and
    # recreating a source branch that delete-branch-on-merge removed (a
    # branch creation fires a real push event) uploaded a NEW store build
    # of the just-promoted version, displacing the recorded RC (the 2.5.0
    # ghost build). Conflict-resolution pushes land on backmerge/<v> too,
    # where they equally trigger nothing. Before the PR opens, the branch's
    # version files are pre-resolved to DEV's version (see
    # build_backmerge_branch) so merging can never regress dev's version.
    def open_back_merge_pr(repo:, version:, kind:, app_dir:)
      source = "#{kind}/#{version}"
      branch = "backmerge/#{version}"
      yield ensure_backmerge_branch(repo: repo, branch: branch, source: source, app_dir: app_dir)

      number = @gh.pr_create(
        repo: repo, base: "dev", head: branch,
        title: "Back-merge #{kind} #{version} into dev",
        body: "Automated back-merge of #{source} into dev. Conflicts? Resolve them here manually. " \
              "Auto-merge is armed with a merge commit — do not squash: dev must inherit main's ancestry, " \
              "or every later release PR conflicts against main."
      )
      # Prefer the created PR's own number; the branch name (dry-run returns
      # no number) is resolved against base dev inside pr_merge_auto.
      arm_true_merge(repo: repo, pr: number || branch)
      Success(:ok)
    # CommandError too: building the backmerge branch runs local git, whose
    # failures must abort record as a Result, never escape as an exception.
    rescue Github::ApiError, Github::CommandError => e
      if TOLERATED_BACK_MERGE_ERRORS.any? { |m| e.message.downcase.include?(m) }
        @out.puts "train: back-merge for #{repo}@#{branch}: #{e.message} (tolerated)"
        # The PR from a prior run may be sitting un-armed (e.g. that run died
        # between create and arm) — re-arm, mirroring Cut#ensure_bump_pr.
        arm_true_merge(repo: repo, pr: branch) if e.message.downcase.include?("already exists")
        return Success(:ok)
      end

      Failure("#{kind} back-merge PR failed for #{repo}: #{e.message}")
    end

    # A squash strips the ancestry the back-merge PR exists to carry, so arm
    # auto-merge pinned to a true merge; base "dev" avoids the same-head
    # release PR to main. Best-effort: Cut#guard_ancestry is the backstop.
    def arm_true_merge(repo:, pr:)
      ok = @gh.pr_merge_auto(repo: repo, head_or_number: pr, methods: ["MERGE"], base: "dev")
      return if ok

      @out.puts "train: warning: could not arm merge-commit auto-merge on #{repo}##{pr} — " \
                "merge it with 'Create a merge commit', never squash"
    rescue Github::ApiError => e
      @out.puts "train: warning: auto-merge arm failed for #{repo}##{pr}: #{e.message}"
    end

    # Release counterpart to the always-on hotfix back-merge. Runs the
    # divergence+author gate, and opens the PR (creating the backmerge/<v>
    # head first, inside open_back_merge_pr) ONLY when a non-bot commit
    # diverged — a clean/bot-only release opens nothing. EVERY git/API
    # step must become a hard Failure, never an escaped exception (binding
    # constraint: aborts record, manifest untouched; the caller only handles the
    # Result contract), so the whole body sits inside one rescue.
    def ensure_release_back_merge(repo:, version:, app_dir:)
      return Success(:ok) unless release_needs_back_merge?(repo: repo, dir: app_dir, version: version)

      open_back_merge_pr(repo: repo, version: version, kind: "release", app_dir: app_dir)
    rescue Github::ApiError, Github::CommandError => e
      Failure("release back-merge check failed for #{repo}: #{e.message}")
    end

    # True only if a NON-bot commit on release/<version> is missing from dev
    # AND was not already on main before this release merged (see the exclusion
    # below — release branches contain main by construction now).
    # SHAs come from the GitHub API on `repo` (dev tip via ls_remote; release tip
    # via ls_remote, falling back to the merged PR's recorded head-sha when the
    # branch was already deleted on merge) — so the decision never depends on
    # app_dir's remote identity or on the release branch still existing, and
    # never mutates anything (dry-run safe, no branch resurrection).
    #
    # The author list is computed locally in `dir` from the two fetched SHAs
    # (works even if the branch ref is gone). `commit_authors` uses `run!`,
    # so a bad ref raises and becomes a hard Failure — fail loud, not open.
    def release_needs_back_merge?(repo:, dir:, version:)
      # `--repo` and `--app-dir` arrive independently on record; the SHAs below
      # come from `dir`'s origin while the PR is opened on `repo`, so confirm the
      # checkout actually IS `repo` first — else a miswired manual run would
      # inspect one repo and open/skip a back-merge in another.
      assert_checkout_is(repo: repo, dir: dir)

      dev_sha = @gh.ls_remote(dir, "refs/heads/dev")
      # A missing dev is an anomaly, not "nothing to do" — fail loud rather than
      # silently skip a back-merge that we simply couldn't evaluate.
      raise Github::ApiError, "no dev branch on #{repo} — cannot evaluate back-merge" if dev_sha.to_s.empty?

      release_tip = release_tip_sha(repo: repo, dir: dir, version: version)
      # Empty tip is legitimate: no release branch AND no merged PR -> nothing to
      # back-merge (e.g. a manual promote of a never-branched version).
      return false if release_tip.to_s.empty?

      # Bring both concrete commits into the local checkout so `git log dev..tip`
      # resolves even if the release branch ref itself is gone (deleted on merge).
      @gh.fetch(dir, dev_sha)
      @gh.fetch(dir, release_tip)

      # Since the cut builds release/<version> as a merge of dev AND main
      # (Cut#ensure_release_branch), `dev..tip` also sweeps in every commit
      # main carried that dev never absorbed — chiefly earlier releases' merge
      # commits, authored by whoever pressed merge rather than by this tool's
      # bot identity. Unfiltered, that would open a back-merge PR on every
      # single release. Excluding what was already on main BEFORE this release
      # merged leaves exactly the release branch's own line of work.
      authors = @gh.commit_authors(dir, "#{dev_sha}..#{release_tip}",
                                   exclude: main_before_release_merge(dir: dir, version: version))
      authors.any? { |email| email != Github::BOT_AUTHOR_EMAIL }
    end

    # main's tip as it stood immediately BEFORE this release merged: the FIRST
    # parent of the release PR's merge commit, which `prepare` has already
    # pushed as the v<version> tag (record always follows prepare, and the tag
    # points at that merge commit by construction). Nothing else in the graph
    # can recover it — by record time main has swallowed the release branch,
    # so merge-base(main, tip) is the tip itself.
    #
    # nil (no exclusion — exactly the pre-2026-08 behavior) whenever the tag
    # or its first parent can't be read: a manual `promote record` with no
    # prepare, a version tagged before any of this existed, a checkout too
    # shallow to hold the parent. That direction is deliberate: a spurious
    # back-merge PR is noise a human closes, while a MISSED back-merge is the
    # divergence this gate exists to prevent.
    def main_before_release_merge(dir:, version:)
      merge_sha = @gh.tag_sha(dir, Versions.tag(version))
      return nil if merge_sha.to_s.empty?

      @gh.fetch(dir, merge_sha)
      @gh.rev_parse(dir, "#{merge_sha}^1")
    rescue Github::CommandError => e
      @out.puts "train: warning: could not resolve main as of the #{version} merge (#{e.message}) — " \
                "the back-merge check runs unexcluded, which over-triggers rather than skipping"
      nil
    end

    # The release branch tip on origin, or the merged PR's head-sha if the
    # branch was deleted on merge; "" if neither exists (nothing to back-merge).
    def release_tip_sha(repo:, dir:, version:)
      tip = @gh.ls_remote(dir, "refs/heads/release/#{version}")
      return tip unless tip.to_s.empty?

      merged_pr_head_sha(repo: repo, branch: "release/#{version}")
    end

    # Fail loud if `dir`'s origin is not the repo we're promoting. Compares the
    # parsed "owner/name" path exactly (both https and scp-like ssh URLs, with or
    # without a trailing .git) — a substring check would accept sibling repos
    # like "<repo>-fork".
    def assert_checkout_is(repo:, dir:)
      origin = @gh.remote_url(dir)
      return if origin_slug(origin) == repo

      raise Github::ApiError, "app-dir #{dir} (origin #{origin}) is not a checkout of #{repo}"
    end

    # "owner/name" iff `url` is a github.com origin (https, ssh://, or scp-like
    # git@github.com:owner/name), else nil. Parses the URL and compares the HOST
    # to "github.com" EXACTLY — a substring/regex approach lets impostor hosts
    # through (notgithub.com, gitlab.com/github.com/...), which would satisfy the
    # checkout-identity guard and let the gate read the wrong repo's commits.
    def origin_slug(url)
      url = url.to_s.strip
      # scp-like "git@github.com:owner/name" has no "://" and uses ":" for the path.
      if !url.include?("://") && (m = url.match(%r{\A(?:[^@]+@)?(?<host>[^/:]+):(?<path>.+)\z}))
        host, path = m[:host], m[:path]
      else
        uri = begin
          URI.parse(url)
        rescue URI::InvalidURIError
          nil
        end
        return nil unless uri&.host && uri.path

        host = uri.host
        path = uri.path.sub(%r{\A/}, "")
      end
      return nil unless host == "github.com"

      slug = path.sub(%r{\.git/?\z}, "").sub(%r{/\z}, "")
      slug.match?(%r{\A[^/]+/[^/]+\z}) ? slug : nil
    end

    # The head-sha of the LAST-merged PR from `branch` into main (max merged_at),
    # or "" if none. GitHub lists PRs newest-CREATED first, so `.find`/`.first`
    # can pick a stale reopened/superseded PR; select by merge time instead.
    # Shared by the release back-merge tip lookup and ensure_backmerge_branch.
    def merged_pr_head_sha(repo:, branch:)
      merged = @gh.pr_list(repo: repo, head: branch, base: "main", state: "all")
                  .select { |pr| pr["merged_at"] }
                  .max_by { |pr| pr["merged_at"] }
      merged ? merged["head-sha"].to_s : ""
    end

    # Ensure backmerge/<version> exists AND cannot regress dev's version.
    #
    # An existing branch is validated, never trusted: a branch left by an
    # older train (or an interrupted run) can still carry the pure version
    # downgrade this whole path exists to prevent, so it is built from ITS
    # OWN tip — append-only, so a human's conflict-resolution commits are
    # preserved and the push stays a fast-forward. A fresh branch is built
    # from `source`'s tip: the live branch when it survived its PR's merge,
    # else the merged PR's recorded head sha (the tag is the MERGE commit,
    # not the tip, so the PR record is the authoritative fallback).
    def ensure_backmerge_branch(repo:, branch:, source:, app_dir:)
      tip = @gh.branch_sha(repo, branch)
      if tip.empty?
        tip = @gh.branch_sha(repo, source)
        tip = merged_pr_head_sha(repo: repo, branch: source) if tip.empty?
      end
      if tip.empty?
        return Failure("#{source} is gone on #{repo} and no merged PR records its head sha — create #{branch} at the back-merge tip manually, then re-run")
      end

      build_backmerge_branch(repo: repo, branch: branch, source: source, tip: tip, app_dir: app_dir)
    end

    # Build the back-merge head at `tip` and push it in ONE step, with the
    # version files pre-resolved to whatever dev currently holds. The 2.5.0
    # release line carried version-reset commits (dev had been merged in
    # repeatedly), so its back-merge PR was a clean-merging pure version
    # downgrade — armed auto-merge would have applied it to dev; only a red
    # version check stopped it. Resetting the versions on the PR head makes
    # that merge unrepresentable, and turns the documented "resolve the
    # version conflict keeping dev's" toil into a no-op for both kinds.
    #
    # The checkout is DETACHED and the push is `HEAD:refs/heads/<branch>`:
    # no local branch is created or reset, so a same-named local branch in
    # the caller's checkout can never be force-moved (and origin never sees
    # a head that could still regress dev). An already-safe branch needs no
    # push at all.
    def build_backmerge_branch(repo:, branch:, source:, tip:, app_dir:)
      # The version surgery commits and pushes from app_dir, so the same
      # miswired-manual-run guard as the release gate applies to both kinds.
      # Absolute: --app-dir is passed through verbatim, and `git -C <dir>`
      # resolves pathspecs from inside <dir>, where a caller-relative path
      # would miss the file it names.
      app_dir = File.expand_path(app_dir)
      assert_checkout_is(repo: repo, dir: app_dir)

      # Dry-run stops HERE: everything below rewrites and detaches the
      # caller's checkout, which mutate!'s remote-only gating wouldn't undo.
      if @gh.dry_run
        @out.puts "[dry-run] would build #{branch} @ #{tip} on #{repo} (version pre-resolved to dev's)"
        return Success(:ok)
      end

      dev_sha = @gh.ls_remote(app_dir, "refs/heads/dev")
      raise Github::ApiError, "no dev branch on #{repo} — cannot build #{branch}" if dev_sha.to_s.empty?

      version_file = Versions.layout_for(app_dir).last
      # Both halves: dirty? is worktree-vs-index, staged? is index-vs-HEAD.
      # Either way the build would carry someone's uncommitted work onto
      # the pushed back-merge head.
      if @gh.dirty?(app_dir, version_file) || @gh.staged?(app_dir, version_file)
        return Failure("#{repo}: #{version_file} has uncommitted changes — commit or discard them, then re-run")
      end

      # The build detaches the checkout; restore whatever it was on, on
      # every path out (record is CI's last train step, but manual runs
      # happen in a human's clone where a stray detached HEAD strands
      # later commits).
      original_head = @gh.head_ref(app_dir)
      begin
        @gh.fetch(app_dir, dev_sha)
        @gh.fetch(app_dir, tip)
        @gh.checkout(app_dir, dev_sha)
        dev_version = Versions.read(app_dir)
        @gh.checkout(app_dir, tip)

        if Versions.read(app_dir) == dev_version
          @out.puts "#{repo}: #{branch} @ #{tip} already carries dev's version #{dev_version}"
          return Success(:ok) if @gh.branch_exists?(repo, branch)
        else
          @gh.git_config_bot(app_dir)
          Versions.bump(app_dir, dev_version)
          # Commit ONLY the version file: bump has already proven its
          # rewrite touched nothing but version lines, and the path-scoped
          # commit keeps any other index/worktree state out of the push.
          @gh.commit(app_dir, "train: keep dev's version #{dev_version} on #{branch}",
                     paths: [version_file])
          @out.puts "#{repo}: reset versions to #{dev_version} on #{branch}"
        end

        # The pushed sha is HEAD, which the reset commit (when there was
        # one) has moved past `tip`.
        pushed = @gh.rev_parse(app_dir)
        unless @gh.push(app_dir, "HEAD:refs/heads/#{branch}")
          return Failure("#{repo}: pushing #{branch} was rejected (moved concurrently?) — re-run")
        end

        @out.puts "#{repo}: pushed #{branch} @ #{pushed} (back-merge head for #{source})"
        Success(:ok)
      ensure
        @gh.checkout(app_dir, original_head)
      end
    rescue Versions::Error => e
      Failure("#{repo}: version pre-resolution on #{branch} failed: #{e.message}")
    # record's contract is a Result, not an exception: the version surgery
    # touches the filesystem directly (read/write/stat), so its Errno and
    # IOError failures must abort as a Failure before the manifest write.
    rescue SystemCallError, IOError => e
      Failure("#{repo}: back-merge build of #{branch} failed: #{e.message}")
    end

    # Platform: the per-platform facts keyed off an app repo's name suffix.
    #   notes_file:   the staged store-notes filename (ios.md / android.md)
    #   artifact_key: the manifest RC key that platform's uploads use —
    #                 convos-ios records TestFlight build numbers,
    #                 convos-client records Play version codes
    #   console:      the store console linked in the staged-submission comment
    Platform = Struct.new(:notes_file, :artifact_key, :console, keyword_init: true)

    PLATFORMS = {
      "convos-ios" => Platform.new(
        notes_file: "ios.md", artifact_key: "build-number",
        console: "https://appstoreconnect.apple.com/apps"
      ),
      "convos-client" => Platform.new(
        notes_file: "android.md", artifact_key: "version-code",
        console: "https://play.google.com/console"
      )
    }.freeze

    # The Platform matching `repo`'s name suffix, or nil for an unrecognized
    # repo — every caller treats "no match" as a no-op, not an error.
    def platform_for(repo)
      suffix = PLATFORMS.keys.find { |s| repo.end_with?(s) }
      suffix && PLATFORMS[suffix]
    end

    # Idempotent state check on the APP repo: a release at `tag` is left alone,
    # an absent one is created with the platform's staged notes as its body.
    # Missing notes warn but still create (empty body), not a hard failure.
    def ensure_release(repo:, tag:, app_dir:)
      return if @gh.release_exists?(repo, tag)

      body = release_body(repo: repo, app_dir: app_dir)
      @gh.create_release(repo, tag: tag, name: tag, body: body)
    end

    def release_body(repo:, app_dir:)
      platform = platform_for(repo)
      notes_file = platform && File.join(app_dir, ".train-promote", platform.notes_file)

      if notes_file && File.exist?(notes_file)
        File.read(notes_file)
      else
        @out.puts "train: warning: no release notes found for #{repo} in #{app_dir}/.train-promote — creating release with an empty body"
        ""
      end
    end

    def post_pr_comment(repo:, tag:, version:, pr_number:)
      console_link = platform_for(repo)&.console

      lines = [
        "**#{tag} staged for submission**",
        "",
        "- artifact: #{tag}"
      ]
      lines << "- console: #{console_link}" if console_link
      lines << "- check: `train status #{version}`"

      @gh.pr_comment(repo, pr_number, lines.join("\n"))
    end

    # The LAST rc entry for head_sha wins — a rerun appends rather than
    # replaces, so the most recent entry is the one uploaded last. Takes the
    # already-read manifest data rather than re-reading.
    def find_rc_entry(data, repo:, head_sha:)
      rc_list = data.dig("repos", repo, "rc") || []
      entry = rc_list.select { |e| e["sha"] == head_sha }.last
      unless entry
        return Failure("no RC recorded for #{head_sha} — did the upload succeed?")
      end

      key = entry.key?("version-code") ? "version-code" : "build-number"
      Success([key, entry[key]])
    end

    # Guards against an RC entry recorded under the WRONG platform's key, which
    # would stage the wrong kind of build number for `repo`. An unrecognized
    # repo (platform_for nil) is a no-op pass.
    def assert_key_matches_platform(repo:, key:)
      platform = platform_for(repo)
      return Success(:ok) unless platform
      return Success(:ok) if key == platform.artifact_key

      Failure("artifact key #{key} does not match #{repo} (expected #{platform.artifact_key})")
    end

    def assert_trees_match(app_dir:, merge_sha:, head_sha:)
      merge_tree = @gh.rev_parse(app_dir, "#{merge_sha}^{tree}")
      head_tree = @gh.rev_parse(app_dir, "#{head_sha}^{tree}")
      return Success(:ok) if merge_tree == head_tree

      Failure("merge tree differs from RC'd branch tip — was this a merge commit of the release branch?")
    end

    # Last gate before the tag: the artifact that was built must claim the
    # version being promoted. A release branch advanced by merging (or
    # fast-forwarding to) dev inherits dev's post-cut bump, so its builds
    # carry the NEXT version while every train artifact still says this one
    # — convos-client shipped 2.5.0 stamped 2.6.0 that way.
    #
    # Read from the BLOB at head_sha, not the worktree: assert_trees_match
    # compares two git objects and says nothing about what is checked out,
    # and a manual --app-dir run can be at any revision or locally edited.
    # head_sha is the RC'd tip the store's artifact was built from, so this
    # is the version the store actually got. The layout still comes from the
    # worktree — that is structural (an iOS repo stays an iOS repo), while
    # the version is content that differs per revision.
    #
    # Fails CLOSED on anything unreadable: absent, malformed, or internally
    # split. "Couldn't tell" must never promote. Placed before ensure_tag so
    # a mismatch costs nothing.
    def assert_rc_version(app_dir:, version:, head_sha:)
      layout, = Versions.layout_for(app_dir)
      content = @gh.show_file(app_dir, head_sha, Versions::REL_PATHS.fetch(layout))
      actual = Versions.read_content(layout, content, label: "#{head_sha}:#{Versions::REL_PATHS.fetch(layout)}")
      return Success(:ok) if actual == version

      Failure("the RC at #{head_sha} is version #{actual}, but #{version} is being promoted — " \
              "the release branch carries a version file that disagrees with the train " \
              "(a merge or fast-forward from dev drags the post-cut bump in does this). " \
              "Reset the version file on the branch, re-merge, and let a fresh RC build.")
    rescue Versions::Error, Github::CommandError => e
      Failure("cannot read the promoted version at #{head_sha}: #{e.message}")
    rescue SystemCallError, IOError => e
      Failure("cannot read the promoted version from #{app_dir}: #{e.message}")
    end

    # Idempotent state check: absent tags get pushed, already-correct is a
    # no-op, anything else is a hard failure (something else claimed the tag).
    def ensure_tag(app_dir:, version:, merge_sha:)
      tag = Versions.tag(version)
      existing = @gh.tag_sha(app_dir, tag)

      if existing.empty?
        unless @gh.push(app_dir, "#{merge_sha}:refs/tags/#{tag}")
          return Failure("tag push failed")
        end

        if @gh.dry_run
          @out.puts "[dry-run] would tag #{tag} @ #{merge_sha}"
        else
          @out.puts "tagged #{tag} @ #{merge_sha}"
        end
      elsif existing == merge_sha
        @out.puts "#{tag}: already tagged"
      else
        return Failure("tag #{tag} exists at #{existing}, expected #{merge_sha}")
      end

      Success(:ok)
    end

    # A hotfix seeds its notes as a describe-the-fix template; if the marker
    # sentence is still present at promote time, nobody edited them and staging
    # would send the placeholder to the store.
    def assert_notes_edited(repo:, version:, notes_dir:)
      platform = platform_for(repo)
      notes_file = platform && File.join(notes_dir, platform.notes_file)
      return Success(:ok) unless notes_file && File.exist?(notes_file)

      if File.read(notes_file).include?(Notes::HOTFIX_PLACEHOLDER)
        return Failure("releases/#{version}/#{platform.notes_file} still contains the seeded placeholder — describe the fix (pencil-edit on convos-releases main), then re-run promotion")
      end

      Success(:ok)
    end

    # Play rejects release notes over 500 chars — fail with the actual
    # overage before the tag push, not a mid-sentence truncation later.
    def assert_notes_fit(repo:, version:, notes_dir:)
      return Success(:ok) unless repo.end_with?("convos-client")

      path = File.join(notes_dir, "android.store.txt")
      return Success(:ok) unless File.exist?(path)

      length = File.read(path, encoding: Encoding::UTF_8).length
      return Success(:ok) if length <= StoreNotes::PLAY_LIMIT

      Failure("android release notes render to #{length} chars (Play limit #{StoreNotes::PLAY_LIMIT}) — trim releases/#{version}/android.md, then re-run promotion")
    end

    NOTES_FILES = %w[ios.md android.md submission-notes.md].freeze
    # The .md files feed the GitHub Release (rendered markdown); every staged
    # file gets a plain-text twin for the stores. Listings drop link URLs;
    # reviewer notes keep them as "text (url)" — App Review needs them.
    STORE_RENDERS = {
      "ios.md" => ["ios.store.txt", :listing],
      "android.md" => ["android.store.txt", :listing],
      "submission-notes.md" => ["submission.store.txt", :reviewer]
    }.freeze

    # notes_dir is recreated from scratch — a leftover .train-promote from an
    # earlier local rerun could otherwise contribute a stale file.
    def copy_notes(clone_dir:, version:, notes_dir:)
      FileUtils.rm_rf(notes_dir)
      FileUtils.mkdir_p(notes_dir)
      src_dir = File.join(clone_dir, "releases", version)
      NOTES_FILES.each do |name|
        src = File.join(src_dir, name)
        next unless File.exist?(src)

        FileUtils.cp(src, File.join(notes_dir, name))
        twin, mode = STORE_RENDERS.fetch(name)
        text = File.read(src, encoding: Encoding::UTF_8)
        rendered = mode == :reviewer ? StoreNotes.render_reviewer(text) : StoreNotes.render(text)
        File.write(File.join(notes_dir, twin), rendered)
      end
      @gh.rev_parse(clone_dir)
    end

    # The staging contract the lanes rely on: the promoting platform's notes
    # must exist (iOS also needs reviewer notes) — fail before the tag push,
    # not in the lane afterwards.
    def assert_notes_present(repo:, version:, notes_dir:)
      platform = platform_for(repo)
      return Success(:ok) unless platform

      required = [platform.notes_file]
      required << "submission-notes.md" if repo.end_with?("convos-ios")
      missing = required.reject { |name| File.exist?(File.join(notes_dir, name)) }
      return Success(:ok) if missing.empty?

      Failure("releases/#{version}/ is missing #{missing.join(", ")} — seed/restore the notes, then re-run promotion")
    end

    def emit_outputs(key:, value:, version:, notes_sha:, notes_dir:)
      outputs = {
        "artifact-key" => key,
        "artifact-value" => value,
        "tag" => Versions.tag(version),
        "notes-sha" => notes_sha,
        "notes-dir" => File.expand_path(notes_dir)
      }

      lines = outputs.map { |k, v| "#{k}=#{v}" }
      lines.each { |line| @out.puts line }

      gh_output = ENV["GITHUB_OUTPUT"]
      return if gh_output.to_s.empty?

      File.open(gh_output, "a") { |f| lines.each { |line| f.puts line } }
    end
  end
end
