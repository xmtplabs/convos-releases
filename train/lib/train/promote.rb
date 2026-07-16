# frozen_string_literal: true

require "fileutils"
require "dry/monads"
require_relative "manifest"
require_relative "state_writer"
require_relative "github"
require_relative "versions"
require_relative "notes"

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

        # Notes staged (and checked) BEFORE the tag push — unedited
        # placeholder notes should stop promotion while nothing has been
        # mutated yet, not after the tag is already claimed.
        notes_dir = File.join(app_dir, ".train-promote")
        notes_sha = copy_notes(clone_dir: dir, version: version, notes_dir: notes_dir)
        yield assert_notes_edited(repo: repo, version: version, notes_dir: notes_dir)

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
      yield open_hotfix_back_merge_pr(repo: repo, version: version) if kind == "hotfix"

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
    # become a Success note. The branch is restored first if absent —
    # delete-branch-on-merge removes it, and a PR can't open from a deleted head.
    def open_hotfix_back_merge_pr(repo:, version:)
      branch = "hotfix/#{version}"
      yield restore_branch_if_deleted(repo: repo, branch: branch)

      @gh.pr_create(
        repo: repo, base: "dev", head: branch,
        title: "Back-merge hotfix #{version} into dev",
        body: "Automated back-merge of hotfix/#{version} into dev. Conflicts? Resolve them here manually."
      )
      Success(:ok)
    rescue Github::ApiError => e
      if TOLERATED_BACK_MERGE_ERRORS.any? { |m| e.message.downcase.include?(m) }
        @out.puts "train: back-merge for #{repo}@hotfix/#{version}: #{e.message} (tolerated)"
        return Success(:ok)
      end

      Failure("hotfix back-merge PR failed for #{repo}: #{e.message}")
    end

    # Recreate hotfix/<version> at the merged PR's recorded head sha — the
    # authoritative tip, since the tag is the MERGE commit, not the tip.
    def restore_branch_if_deleted(repo:, branch:)
      return Success(:ok) if @gh.branch_exists?(repo, branch)

      merged = @gh.pr_list(repo: repo, head: branch, base: "main", state: "all").find { |pr| pr["merged_at"] }
      unless merged && merged["head-sha"]
        return Failure("#{branch} is gone on #{repo} and no merged PR records its head sha — restore the branch manually, then re-run")
      end

      @gh.create_ref(repo, branch: branch, sha: merged["head-sha"])
      @out.puts "#{repo}: restored #{branch} @ #{merged["head-sha"]} (deleted on merge)"
      Success(:ok)
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

    NOTES_FILES = %w[ios.md android.md submission-notes.md].freeze

    # notes_dir is recreated from scratch — a leftover .train-promote from an
    # earlier local rerun could otherwise contribute a stale file.
    def copy_notes(clone_dir:, version:, notes_dir:)
      FileUtils.rm_rf(notes_dir)
      FileUtils.mkdir_p(notes_dir)
      src_dir = File.join(clone_dir, "releases", version)
      NOTES_FILES.each do |name|
        src = File.join(src_dir, name)
        FileUtils.cp(src, File.join(notes_dir, name)) if File.exist?(src)
      end
      @gh.rev_parse(clone_dir)
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
