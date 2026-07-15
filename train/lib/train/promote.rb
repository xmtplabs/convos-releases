# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "dry/monads"
require_relative "manifest"
require_relative "state_writer"
require_relative "github"
require_relative "versions"
require_relative "notes"

module Train
  # Ports the "Promote" step of the release train: given a merged release
  # PR (merge_sha) and the release-branch tip it was merged from (head_sha),
  # verify the RC that was uploaded from head_sha is the one being promoted,
  # tag the merge commit, and stage the release notes for the next step
  # (store submission) to consume. Runs FROM the app-repo checkout (cwd);
  # the convos-releases clone is made internally, fresh, same as Append —
  # so promotion always reads whatever's CURRENT on convos-releases main.
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

      dir = Dir.mktmpdir("train-promote-")
      begin
        @gh.clone(
          "https://x-access-token:#{ENV["GH_TOKEN"]}@github.com/xmtplabs/convos-releases.git",
          dir, depth: 1
        )
        mfile = File.join(dir, "releases", version, "manifest.yml")
        return Failure("no manifest for #{version}") unless File.exist?(mfile)

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
      ensure
        FileUtils.remove_entry(dir) if Dir.exist?(dir)
      end
    end

    # record: the "Record promotion" step — for a hotfix, FIRST opens the
    # back-merge PR (hard-gated: a real API failure aborts before anything
    # is written — see open_hotfix_back_merge_pr), THEN writes the promoted
    # block into convos-releases' manifest (via StateWriter, same retry
    # semantics as Append), ensures a GitHub Release exists on the APP repo
    # for `tag` (creating it from the platform notes staged by `prepare` if
    # absent), and — when `pr_number` is given — posts a staged-submission
    # summary comment on that PR. The manifest's "kind" is read from the
    # manifest itself (a fresh read-only clone, same as prepare) rather
    # than trusted from a flag — a mis-supplied kind on a manual run would
    # otherwise skip a hotfix's required back-merge, or open a bogus one
    # for a release. Returns a Result: Success(true) on completion
    # (including dry-run and no-op writes), Failure(message) if the
    # back-merge hard-fails or the manifest write's retries are
    # exhausted/fail hard.
    def record(repo:, version:, tag:, key:, value:, notes_sha:, run_url:, pr_number: nil, app_dir: Dir.pwd)
      # Pre-validate BEFORE any I/O (mirrors Append#run): a bad artifact id
      # must fail fast as a Result, not surface as a Manifest::Error raised
      # from inside the StateWriter loop after a clone.
      yield assert_version_format(version)

      # The tag is always v<version> (prepare mints it that way) — a
      # mismatched pair on a manual run would promote one version in the
      # manifest while staging a GitHub Release for another.
      unless tag == "v#{version}"
        return Failure("record: --tag must be v#{version}, got '#{tag}'")
      end

      value_str = value.to_s
      unless value_str.match?(Manifest::POSITIVE_INT_RE)
        return Failure("record: --value must be a positive integer, got '#{value_str}'")
      end

      # Same key<->platform guard as prepare: record is also invocable
      # directly (manual runs), where a mistyped --key would otherwise be
      # written into the manifest under the wrong artifact field.
      yield assert_key_matches_platform(repo: repo, key: key)

      # Reading kind here (not from a flag) also means a nonexistent
      # manifest fails now, before any back-merge PR is opened.
      kind = yield read_manifest_kind(version)

      # Back-merge BEFORE the manifest write for a hotfix: a hard failure
      # here (repo unreachable, auth failure, etc.) must leave the manifest
      # untouched (no push) rather than recording a promotion whose
      # back-merge never happened. "Already exists"/"no commits between"
      # are expected on a rerun (the PR was already opened, or the branches
      # are already level) and are tolerated as success-notes, not failures.
      yield open_hotfix_back_merge_pr(repo: repo, version: version) if kind == "hotfix"

      yield record_promotion(repo: repo, version: version, key: key, value: value_str, tag: tag, notes_sha: notes_sha, run_url: run_url)

      ensure_release(repo: repo, tag: tag, app_dir: app_dir)

      post_pr_comment(repo: repo, tag: tag, version: version, pr_number: pr_number) if pr_number

      Success(true)
    end

    private

    # assert_version_format: `version` arrives from a caller-resolved
    # branch name and is used in file paths and refs — reject anything
    # that isn't X.Y.Z before it touches either.
    def assert_version_format(version)
      return Success(:ok) if version.match?(Versions::VERSION_RE)

      Failure("version must look like X.Y.Z, got '#{version}'")
    end

    # read_manifest_kind: the version's manifest "kind" via a fresh,
    # read-only, depth-1 clone (same approach as prepare and Merge) —
    # record decides the back-merge step from the manifest's own state,
    # never from caller input.
    def read_manifest_kind(version)
      dir = Dir.mktmpdir("train-record-")
      begin
        @gh.clone(
          "https://x-access-token:#{ENV["GH_TOKEN"]}@github.com/xmtplabs/convos-releases.git",
          dir, depth: 1
        )
        mfile = File.join(dir, "releases", version, "manifest.yml")
        return Failure("no manifest for #{version}") unless File.exist?(mfile)

        Success(Manifest.read(mfile).fetch("kind"))
      ensure
        FileUtils.remove_entry(dir) if Dir.exist?(dir)
      end
    end

    # record_promotion: the StateWriter-backed clone/mutate/commit/push
    # loop, mutating the convos-releases clone via Manifest.record_promotion.
    # An unchanged (already-recorded) block is still a successful, no-op
    # write.
    def record_promotion(repo:, version:, key:, value:, tag:, notes_sha:, run_url:)
      @writer.write(message: "train: promoted #{repo}@#{tag}") do |dir|
        mfile = File.join(dir, "releases", version, "manifest.yml")
        next Failure("no manifest for #{version}") unless File.exist?(mfile)

        Manifest.record_promotion(mfile, repo: repo, key: key, value: value, tag: tag, notes_sha: notes_sha, run: run_url)
        Success(true)
      end
    end

    # TOLERATED_BACK_MERGE_ERRORS: substrings (matched case-insensitively)
    # of a back-merge pr_create ApiError that mean "this already happened,
    # not a real failure" — a rerun after record already opened the PR
    # ("A pull request already exists for ..."), or the hotfix branch is
    # already fully merged into dev with nothing left to back-merge ("No
    # commits between dev and hotfix/...").
    TOLERATED_BACK_MERGE_ERRORS = [
      "a pull request already exists",
      "no commits between"
    ].freeze

    # open_hotfix_back_merge_pr: hard-gated — unlike the old best-effort
    # behavior, a genuine API failure (repo unreachable, auth failure, bad
    # credentials, etc.) now returns Failure and must abort `record` before
    # the manifest is ever written. Only the two expected "already handled"
    # outcomes above are downgraded to a printed note + Success.
    #
    # The branch is restored first if absent: delete-branch-on-merge
    # (enabled on convos-ios) removes hotfix/<version> the moment its main
    # PR merges, and a PR can't be opened from a deleted head — without the
    # restore, promotion would wedge permanently (no rerun brings the
    # branch back).
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

    # restore_branch_if_deleted: recreate hotfix/<version> at the merged
    # PR's recorded head sha. The merged PR is the authoritative source for
    # where the branch pointed — the tag is the MERGE commit, not the tip.
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

    NOTES_BY_REPO_SUFFIX = {
      "convos-ios" => "ios.md",
      "convos-client" => "android.md"
    }.freeze

    # ensure_release: idempotent state check on the APP repo (not
    # convos-releases) — a release already at `tag` is left alone; an
    # absent one is created with the matching platform's staged notes as
    # its body. Missing notes are not a hard failure (the release still
    # gets created, just with an empty body) — a warning is printed so a
    # silently-empty release body doesn't go unnoticed.
    def ensure_release(repo:, tag:, app_dir:)
      return if @gh.release_exists?(repo, tag)

      body = release_body(repo: repo, app_dir: app_dir)
      @gh.create_release(repo, tag: tag, name: tag, body: body)
    end

    def release_body(repo:, app_dir:)
      suffix = NOTES_BY_REPO_SUFFIX.keys.find { |s| repo.end_with?(s) }
      notes_file = suffix && File.join(app_dir, ".train-promote", NOTES_BY_REPO_SUFFIX[suffix])

      if notes_file && File.exist?(notes_file)
        File.read(notes_file)
      else
        @out.puts "train: warning: no release notes found for #{repo} in #{app_dir}/.train-promote — creating release with an empty body"
        ""
      end
    end

    CONSOLE_LINKS = {
      "convos-ios" => "https://appstoreconnect.apple.com/apps",
      "convos-client" => "https://play.google.com/console"
    }.freeze

    def post_pr_comment(repo:, tag:, version:, pr_number:)
      suffix = CONSOLE_LINKS.keys.find { |s| repo.end_with?(s) }
      console_link = suffix ? CONSOLE_LINKS[suffix] : nil

      lines = [
        "**#{tag} staged for submission**",
        "",
        "- artifact: #{tag}"
      ]
      lines << "- console: #{console_link}" if console_link
      lines << "- check: `train status #{version}`"

      @gh.pr_comment(repo, pr_number, lines.join("\n"))
    end

    # find_rc_entry: the LAST rc entry recorded for head_sha wins — a rerun
    # that produced a new artifact id for the same sha appends rather than
    # replaces (see Manifest.append_rc), so the most recent entry is the one
    # actually uploaded last. Takes the already-read manifest data (prepare
    # reads it once, at the top of its clone block) rather than re-reading
    # the file itself.
    def find_rc_entry(data, repo:, head_sha:)
      rc_list = data.dig("repos", repo, "rc") || []
      entry = rc_list.select { |e| e["sha"] == head_sha }.last
      unless entry
        return Failure("no RC recorded for #{head_sha} — did the upload succeed?")
      end

      key = entry.key?("version-code") ? "version-code" : "build-number"
      Success([key, entry[key]])
    end

    # EXPECTED_KEY_BY_REPO_SUFFIX: the artifact-key each platform's RC
    # entries are recorded under (Append#run / append-rc's --key,
    # ultimately the app repo's own upload workflow) — convos-ios uploads
    # TestFlight build numbers, convos-client uploads Play version codes.
    EXPECTED_KEY_BY_REPO_SUFFIX = {
      "convos-ios" => "build-number",
      "convos-client" => "version-code"
    }.freeze

    # assert_key_matches_platform: guards against a manifest whose RC entry
    # was recorded under the WRONG platform's key (e.g. a copy/paste error
    # in an app repo's upload workflow, or --key passed to append-rc for the
    # wrong repo) — proceeding would silently record and stage the wrong
    # kind of build number for `repo`. An unrecognized repo suffix is not
    # this check's problem (no expectation to violate); the platform-suffix
    # tables elsewhere in this class already treat that as a "no match"
    # no-op rather than an error.
    def assert_key_matches_platform(repo:, key:)
      expected = EXPECTED_KEY_BY_REPO_SUFFIX.keys.find { |suffix| repo.end_with?(suffix) }
      return Success(:ok) unless expected

      expected_key = EXPECTED_KEY_BY_REPO_SUFFIX[expected]
      return Success(:ok) if key == expected_key

      Failure("artifact key #{key} does not match #{repo} (expected #{expected_key})")
    end

    def assert_trees_match(app_dir:, merge_sha:, head_sha:)
      merge_tree = @gh.rev_parse(app_dir, "#{merge_sha}^{tree}")
      head_tree = @gh.rev_parse(app_dir, "#{head_sha}^{tree}")
      return Success(:ok) if merge_tree == head_tree

      Failure("merge tree differs from RC'd branch tip — was this a merge commit of the release branch?")
    end

    # ensure_tag: idempotent state check — absent tags get pushed (under
    # dry-run, push's mutate! gate returns its `default: true` without
    # touching origin, so this never falsely fails a dry-run); already
    # correct is a no-op note; anywhere else is a hard failure (someone/
    # something else claimed this tag).
    def ensure_tag(app_dir:, version:, merge_sha:)
      tag = "v#{version}"
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

    # assert_notes_edited: a hotfix seeds its platform notes as a
    # describe-the-fix TEMPLATE (see Hotfix#write_seed_notes) — if the
    # marker sentence is still present at promote time, nobody edited them,
    # and staging would send the placeholder to the store listing.
    def assert_notes_edited(repo:, version:, notes_dir:)
      suffix = NOTES_BY_REPO_SUFFIX.keys.find { |s| repo.end_with?(s) }
      notes_file = suffix && File.join(notes_dir, NOTES_BY_REPO_SUFFIX[suffix])
      return Success(:ok) unless notes_file && File.exist?(notes_file)

      if File.read(notes_file).include?(Notes::HOTFIX_PLACEHOLDER)
        return Failure("releases/#{version}/#{NOTES_BY_REPO_SUFFIX[suffix]} still contains the seeded placeholder — describe the fix (pencil-edit on convos-releases main), then re-run promotion")
      end

      Success(:ok)
    end

    NOTES_FILES = %w[ios.md android.md submission-notes.md].freeze

    # copy_notes: notes_dir is recreated from scratch — a leftover
    # .train-promote from an earlier run (possible on manual/local reruns;
    # CI checkouts are fresh) could otherwise contribute a stale file that
    # the current release source no longer has.
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
        "tag" => "v#{version}",
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
