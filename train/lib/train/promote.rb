# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "dry/monads"
require_relative "manifest"
require_relative "state_writer"
require_relative "github"

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
      dir = Dir.mktmpdir("train-promote-")
      begin
        @gh.clone(
          "https://x-access-token:#{ENV["GH_TOKEN"]}@github.com/xmtplabs/convos-releases.git",
          dir, depth: 1
        )
        mfile = File.join(dir, "releases", version, "manifest.yml")
        return Failure("no manifest for #{version}") unless File.exist?(mfile)

        rc = yield find_rc_entry(mfile, repo: repo, head_sha: head_sha)
        key, value = rc

        yield assert_trees_match(app_dir: app_dir, merge_sha: merge_sha, head_sha: head_sha)
        yield ensure_tag(app_dir: app_dir, version: version, merge_sha: merge_sha)

        notes_dir = File.join(app_dir, ".train-promote")
        notes_sha = copy_notes(clone_dir: dir, version: version, notes_dir: notes_dir)

        emit_outputs(key: key, value: value, version: version, notes_sha: notes_sha, notes_dir: notes_dir)

        Success(true)
      ensure
        FileUtils.remove_entry(dir) if Dir.exist?(dir)
      end
    end

    # record: the "Record promotion" step — writes the promoted block into
    # convos-releases' manifest (via StateWriter, same retry semantics as
    # Append), ensures a GitHub Release exists on the APP repo for `tag`
    # (creating it from the platform notes staged by `prepare` if absent),
    # and — when `pr_number` is given — posts a staged-submission summary
    # comment on that PR. Returns a Result: Success(true) on completion
    # (including dry-run and no-op writes), Failure(message) if the
    # manifest write's retries are exhausted or fail hard.
    def record(repo:, version:, tag:, key:, value:, notes_sha:, run_url:, pr_number: nil, app_dir: Dir.pwd)
      # Pre-validate BEFORE any I/O (mirrors Append#run): a bad artifact id
      # must fail fast as a Result, not surface as a Manifest::Error raised
      # from inside the StateWriter loop after a clone.
      value_str = value.to_s
      unless value_str.match?(Manifest::POSITIVE_INT_RE)
        return Failure("record: --value must be a positive integer, got '#{value_str}'")
      end

      kind_holder = {}
      yield record_promotion(repo: repo, version: version, key: key, value: value_str, tag: tag, notes_sha: notes_sha, run_url: run_url, kind_holder: kind_holder)

      ensure_release(repo: repo, tag: tag, app_dir: app_dir)

      post_pr_comment(repo: repo, tag: tag, version: version, pr_number: pr_number) if pr_number

      open_hotfix_back_merge_pr(repo: repo, version: version) if kind_holder[:kind] == "hotfix"

      Success(true)
    end

    private

    # record_promotion: the StateWriter-backed clone/mutate/commit/push
    # loop, mutating the convos-releases clone via Manifest.record_promotion.
    # An unchanged (already-recorded) block is still a successful, no-op
    # write — record_promotion's boolean return isn't surfaced up through
    # the Result, only used for the commit message. StateWriter#write always
    # returns Success(true) on its happy path (discarding whatever Success
    # value the block itself produced), so the manifest's "kind" — needed by
    # `record` afterward to decide whether to open a hotfix back-merge PR —
    # is threaded out via `kind_holder` (mutated as a side effect) rather
    # than through the Result. It already reads the manifest file here, so
    # this avoids a second clone just to look up "kind".
    def record_promotion(repo:, version:, key:, value:, tag:, notes_sha:, run_url:, kind_holder:)
      @writer.write(message: "train: promoted #{repo}@#{tag}") do |dir|
        mfile = File.join(dir, "releases", version, "manifest.yml")
        next Failure("no manifest for #{version}") unless File.exist?(mfile)

        data = Manifest.read(mfile)
        kind_holder[:kind] = data["kind"]
        Manifest.record_promotion(mfile, repo: repo, key: key, value: value, tag: tag, notes_sha: notes_sha, run: run_url)
        Success(true)
      end
    end

    # open_hotfix_back_merge_pr: best-effort — a conflicting back-merge is
    # expected and handled by a human on the PR itself, not by this tool, so
    # only a hard API error (repo unreachable, auth failure, etc.) is
    # swallowed here (warn, don't fail the overall `record`).
    def open_hotfix_back_merge_pr(repo:, version:)
      @gh.pr_create(
        repo: repo, base: "dev", head: "hotfix/#{version}",
        title: "Back-merge hotfix #{version} into dev",
        body: "Automated back-merge of hotfix/#{version} into dev. Conflicts? Resolve them here manually."
      )
    rescue Github::ApiError => e
      @out.puts "train: warning: hotfix back-merge PR failed for #{repo}: #{e.message}"
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
    # actually uploaded last.
    def find_rc_entry(mfile, repo:, head_sha:)
      data = Manifest.read(mfile)
      rc_list = data.dig("repos", repo, "rc") || []
      entry = rc_list.select { |e| e["sha"] == head_sha }.last
      unless entry
        return Failure("no RC recorded for #{head_sha} — did the upload succeed?")
      end

      key = entry.key?("version-code") ? "version-code" : "build-number"
      Success([key, entry[key]])
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

    NOTES_FILES = %w[ios.md android.md submission-notes.md].freeze

    def copy_notes(clone_dir:, version:, notes_dir:)
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
