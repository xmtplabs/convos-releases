# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "dry/monads"
require "train/promote"
require "train/manifest"
require_relative "support/fake_github"

class PromoteTest < Minitest::Test
  REPO = "xmtplabs/convos-ios"
  VERSION = "2.1.0"
  MERGE_SHA = "merge-sha-abc"
  HEAD_SHA = "head-sha-def"

  def setup
    @out = StringIO.new
    @gh = FakeGithub.new
    @app_dir = Dir.mktmpdir("train-promote-app-")
  end

  def teardown
    FileUtils.remove_entry(@app_dir) if Dir.exist?(@app_dir)
  end

  def new_promote(gh = @gh)
    Train::Promote.new(github: gh, out: @out)
  end

  # write_manifest_fixture: registers the convos-releases clone fixture with
  # a manifest containing one rc entry (sha: HEAD_SHA) plus notes files.
  # rc_entries lets tests script multiple entries (e.g. last-wins).
  def write_manifest_fixture(gh = @gh, repo: REPO,
                             rc_entries: [{ "sha" => HEAD_SHA, "run" => "https://run/1", "build-number" => 100 }],
                             notes_head_sha: "notes-clone-sha")
    gh.stub_clone("convos-releases") do |dest|
      write_manifest_fixture_into(dest, repo: repo, rc_entries: rc_entries)
      gh.stub_rev_parse(File.basename(dest), "HEAD", notes_head_sha)
    end
  end

  # stub_matching_trees: app_dir's merge-sha and head-sha resolve to the
  # SAME tree sha — the happy-path tree assert.
  def stub_matching_trees(tree_sha: "tree-sha-1")
    @gh.stub_rev_parse(File.basename(@app_dir), "#{MERGE_SHA}^{tree}", tree_sha)
    @gh.stub_rev_parse(File.basename(@app_dir), "#{HEAD_SHA}^{tree}", tree_sha)
  end

  def base_args
    { repo: REPO, version: VERSION, merge_sha: MERGE_SHA, head_sha: HEAD_SHA, app_dir: @app_dir }
  end

  # ---- happy path ----

  def test_prepare_happy_path_success
    write_manifest_fixture
    stub_matching_trees
    @gh.stub_tag_sha("v#{VERSION}", "")

    result = new_promote.prepare(**base_args)

    assert_instance_of Dry::Monads::Result::Success, result

    notes_dir = File.join(@app_dir, ".train-promote")
    assert File.exist?(File.join(notes_dir, "ios.md"))
    assert File.exist?(File.join(notes_dir, "android.md"))
    assert File.exist?(File.join(notes_dir, "submission-notes.md"))
    assert_equal "## Features\n- ios note\n", File.read(File.join(notes_dir, "ios.md"))

    push_calls = @gh.calls_for(:push)
    assert_equal 1, push_calls.size
    assert_equal "#{MERGE_SHA}:refs/tags/v#{VERSION}", push_calls.first.args[1]

    out = @out.string
    assert_match(/artifact-key=build-number/, out)
    assert_match(/artifact-value=100/, out)
    assert_match(/tag=v#{VERSION}/, out)
    assert_match(/notes-sha=notes-clone-sha/, out)
    assert_match(/notes-dir=#{Regexp.escape(notes_dir)}/, out)
  end

  def test_prepare_recreates_notes_dir_dropping_stale_files
    write_manifest_fixture
    stub_matching_trees
    @gh.stub_tag_sha("v#{VERSION}", "")

    # A leftover .train-promote from an earlier run (manual/local rerun)
    # holds a file the current release source doesn't have.
    notes_dir = File.join(@app_dir, ".train-promote")
    FileUtils.mkdir_p(notes_dir)
    File.write(File.join(notes_dir, "stale.md"), "from a previous version")

    result = new_promote.prepare(**base_args)

    assert_instance_of Dry::Monads::Result::Success, result
    refute File.exist?(File.join(notes_dir, "stale.md")), "notes dir must be recreated from scratch"
    assert File.exist?(File.join(notes_dir, "ios.md"))
  end

  def test_prepare_blocks_unedited_hotfix_placeholder_notes
    # A hotfix seeds platform notes as a template; promoting without
    # pencil-editing them must fail BEFORE the tag is pushed.
    @gh.stub_clone("convos-releases") do |dest|
      mdir = File.join(dest, "releases", VERSION)
      FileUtils.mkdir_p(mdir)
      Train::Manifest.init(
        File.join(mdir, "manifest.yml"), version: VERSION, kind: "hotfix", cut_date: "2026-07-16",
        repos: { REPO => "source-sha" }
      )
      data = Train::Manifest.read(File.join(mdir, "manifest.yml"))
      data["repos"][REPO]["rc"] = [{ "sha" => HEAD_SHA, "run" => "https://run/1", "build-number" => 100 }]
      Train::Manifest.write(File.join(mdir, "manifest.yml"), data)

      File.write(File.join(mdir, "ios.md"), "# Hotfix from v2.0.9\n\n_#{Train::Notes::HOTFIX_PLACEHOLDER}; edit me._\n")
      File.write(File.join(mdir, "submission-notes.md"), "# Submission notes\n")
    end
    stub_matching_trees
    @gh.stub_tag_sha("v#{VERSION}", "")

    result = new_promote.prepare(**base_args)

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/ios\.md still contains the seeded placeholder/, result.failure)
    refute @gh.called?(:push), "placeholder notes must stop promotion before the tag is pushed"
  end

  def test_prepare_writes_github_output_when_set
    write_manifest_fixture
    stub_matching_trees
    @gh.stub_tag_sha("v#{VERSION}", "")

    gh_output = File.join(@app_dir, "gh_output.txt")
    ENV["GITHUB_OUTPUT"] = gh_output
    begin
      result = new_promote.prepare(**base_args)
      assert_instance_of Dry::Monads::Result::Success, result

      contents = File.read(gh_output)
      assert_match(/^artifact-key=build-number$/, contents)
      assert_match(/^artifact-value=100$/, contents)
      assert_match(/^tag=v#{VERSION}$/, contents)
      assert_match(/^notes-sha=notes-clone-sha$/, contents)
      assert_match(/^notes-dir=/, contents)
    ensure
      ENV.delete("GITHUB_OUTPUT")
    end
  end

  # ---- last-rc-entry-wins ----

  def test_last_matching_rc_entry_wins
    write_manifest_fixture(rc_entries: [
      { "sha" => HEAD_SHA, "run" => "https://run/1", "build-number" => 100 },
      { "sha" => "other-sha", "run" => "https://run/2", "build-number" => 200 },
      { "sha" => HEAD_SHA, "run" => "https://run/3", "build-number" => 150 }
    ])
    stub_matching_trees
    @gh.stub_tag_sha("v#{VERSION}", "")

    result = new_promote.prepare(**base_args)

    assert_instance_of Dry::Monads::Result::Success, result
    assert_match(/artifact-value=150/, @out.string)
  end

  # ---- version-code key variant ----

  ANDROID_REPO = "xmtplabs/convos-client"

  def test_supports_version_code_key
    # version-code is the convos-client (android) key — the fixture uses
    # ANDROID_REPO to match, since the artifact-key/platform check would
    # otherwise reject version-code recorded against convos-ios.
    write_manifest_fixture(repo: ANDROID_REPO,
                           rc_entries: [{ "sha" => HEAD_SHA, "run" => "https://run/1", "version-code" => 77 }])
    stub_matching_trees
    @gh.stub_tag_sha("v#{VERSION}", "")

    result = new_promote.prepare(**base_args.merge(repo: ANDROID_REPO))

    assert_instance_of Dry::Monads::Result::Success, result
    assert_match(/artifact-key=version-code/, @out.string)
    assert_match(/artifact-value=77/, @out.string)
  end

  # ---- artifact-key / platform validation ----

  def test_ios_repo_with_version_code_key_is_a_failure
    # xmtplabs/convos-ios's RC entry recorded under the WRONG platform's
    # key (version-code is convos-client's) — must fail loud rather than
    # silently staging the wrong kind of build identifier.
    write_manifest_fixture(rc_entries: [{ "sha" => HEAD_SHA, "run" => "https://run/1", "version-code" => 77 }])

    result = new_promote.prepare(**base_args)

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/artifact key version-code does not match #{Regexp.escape(REPO)} \(expected build-number\)/, result.failure)
    refute @gh.called?(:push), "an artifact-key mismatch must fail before any tag push"
  end

  def test_android_repo_with_build_number_key_is_a_failure
    write_manifest_fixture(repo: ANDROID_REPO,
                           rc_entries: [{ "sha" => HEAD_SHA, "run" => "https://run/1", "build-number" => 100 }])

    result = new_promote.prepare(**base_args.merge(repo: ANDROID_REPO))

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/artifact key build-number does not match #{Regexp.escape(ANDROID_REPO)} \(expected version-code\)/, result.failure)
    refute @gh.called?(:push), "an artifact-key mismatch must fail before any tag push"
  end

  # ---- failure paths ----

  def test_no_manifest_for_version_is_a_failure
    @gh.stub_clone("convos-releases") { |dest| FileUtils.mkdir_p(File.join(dest, "releases")) }

    result = new_promote.prepare(**base_args)

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/no manifest for #{VERSION}/, result.failure)
  end

  def test_no_rc_entry_for_head_sha_is_a_failure
    write_manifest_fixture(rc_entries: [{ "sha" => "some-other-sha", "run" => "https://run/1", "build-number" => 100 }])

    result = new_promote.prepare(**base_args)

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/no RC recorded for #{HEAD_SHA}/, result.failure)
    assert_match(/did the upload succeed/, result.failure)
  end

  def test_tree_mismatch_is_a_failure
    write_manifest_fixture
    @gh.stub_rev_parse(File.basename(@app_dir), "#{MERGE_SHA}^{tree}", "tree-a")
    @gh.stub_rev_parse(File.basename(@app_dir), "#{HEAD_SHA}^{tree}", "tree-b")

    result = new_promote.prepare(**base_args)

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/merge tree differs from RC'd branch tip/, result.failure)
    refute @gh.called?(:push), "tree mismatch must fail before any tag push"
  end

  def test_tag_exists_elsewhere_is_a_failure
    write_manifest_fixture
    stub_matching_trees
    @gh.stub_tag_sha("v#{VERSION}", "some-other-sha")

    result = new_promote.prepare(**base_args)

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/tag v#{VERSION} exists at some-other-sha, expected #{MERGE_SHA}/, result.failure)
    refute @gh.called?(:push), "tag-elsewhere must not attempt a push"
  end

  def test_tag_already_at_merge_sha_succeeds_without_push
    write_manifest_fixture
    stub_matching_trees
    @gh.stub_tag_sha("v#{VERSION}", MERGE_SHA)

    result = new_promote.prepare(**base_args)

    assert_instance_of Dry::Monads::Result::Success, result
    refute @gh.called?(:push), "already-tagged-at-merge-sha must not push again"
    assert_match(/already tagged/, @out.string)
  end

  def test_tag_push_failure_is_a_failure
    write_manifest_fixture
    stub_matching_trees
    @gh.stub_tag_sha("v#{VERSION}", "")
    @gh.fail_push_times("#{MERGE_SHA}:refs/tags/v#{VERSION}", 99)

    result = new_promote.prepare(**base_args)

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/tag push failed/, result.failure)
  end

  # ---- dry-run ----

  def test_dry_run_does_not_mutate_tag
    gh = FakeGithub.new(dry_run: true)
    write_manifest_fixture(gh)
    gh.stub_rev_parse(File.basename(@app_dir), "#{MERGE_SHA}^{tree}", "tree-x")
    gh.stub_rev_parse(File.basename(@app_dir), "#{HEAD_SHA}^{tree}", "tree-x")
    gh.stub_tag_sha("v#{VERSION}", "")

    result = new_promote(gh).prepare(**base_args)

    assert_instance_of Dry::Monads::Result::Success, result
    assert_match(/\[dry-run\]/, @out.string)
  end

  # ---- record ----

  def record_args(overrides = {})
    {
      repo: REPO, version: VERSION, tag: "v#{VERSION}", key: "build-number", value: "421",
      notes_sha: "notes-sha-1", run_url: "https://run/1", app_dir: @app_dir
    }.merge(overrides)
  end

  # stub_releases_clone: registers the convos-releases clone fixture used by
  # `record` — a plain manifest with one repo, no rc/promoted state yet.
  # `kind:` selects release (default) vs hotfix, which drives the back-merge.
  def stub_releases_clone(gh = @gh, kind: "release", repos: { REPO => "source-sha" })
    gh.stub_clone("convos-releases") do |dest|
      mdir = File.join(dest, "releases", VERSION)
      FileUtils.mkdir_p(mdir)
      Train::Manifest.init(
        File.join(mdir, "manifest.yml"), version: VERSION, kind: kind, cut_date: "2026-07-16",
        repos: repos
      )
    end
  end

  def write_notes(app_dir: @app_dir, ios: nil, android: nil)
    notes_dir = File.join(app_dir, ".train-promote")
    FileUtils.mkdir_p(notes_dir)
    File.write(File.join(notes_dir, "ios.md"), ios) if ios
    File.write(File.join(notes_dir, "android.md"), android) if android
  end

  def test_record_writes_promoted_block_through_the_state_writer
    stub_releases_clone

    result = new_promote.record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    # Two clones: the read-only kind lookup + the StateWriter write loop.
    assert_equal 2, @gh.calls_for(:clone).size
    assert_equal 1, @gh.calls_for(:commit).size
    assert_equal "train: promoted #{REPO}@v#{VERSION}", @gh.calls_for(:commit).first.args[1]
    assert_equal 1, @gh.calls_for(:push).size
  end

  def test_record_creates_release_when_absent
    stub_releases_clone
    write_notes(ios: "## iOS notes\n")

    result = new_promote.record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    assert @gh.called?(:create_release)
    assert_equal "## iOS notes\n", @gh.release_body(REPO, "v#{VERSION}")
  end

  def test_prepare_rejects_malformed_version_before_any_io
    result = new_promote.prepare(**base_args.merge(version: "2.1.0/../evil"))

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/version must look like X\.Y\.Z/, result.failure)
    refute @gh.called?(:clone), "a malformed version must fail before any clone"
  end

  def test_record_rejects_malformed_version_before_any_io
    result = new_promote.record(**record_args(version: "2.1.0$(boom)"))

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/version must look like X\.Y\.Z/, result.failure)
    refute @gh.called?(:clone)
  end

  def test_record_rejects_tag_not_matching_version_before_any_io
    result = new_promote.record(**record_args(tag: "v9.9.9"))

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/--tag must be v#{VERSION}, got 'v9\.9\.9'/, result.failure)
    refute @gh.called?(:clone)
  end

  def test_record_reads_kind_from_the_manifest_not_caller_input
    # No kind parameter exists anymore — a hotfix manifest triggers the
    # back-merge purely from its own recorded kind.
    stub_releases_clone(kind: "hotfix")

    result = new_promote.record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    assert(@gh.calls_for(:pr_create).any? { |c| c.kwargs[:base] == "dev" })
  end

  def test_record_rejects_non_integer_value_before_any_io
    stub_releases_clone

    ["abc", "0", "000"].each do |bad|
      result = new_promote.record(**record_args(value: bad))

      assert_instance_of Dry::Monads::Result::Failure, result
      assert_match(/positive integer/, result.failure)
      refute @gh.called?(:clone), "a bad --value must fail before the StateWriter ever clones"
      refute @gh.called?(:release_exists?), "a bad --value must fail before the release check"
    end
  end

  def test_record_rejects_wrong_platform_key_before_any_io
    stub_releases_clone

    result = new_promote.record(**record_args(key: "version-code"))

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/artifact key version-code does not match #{Regexp.escape(REPO)} \(expected build-number\)/, result.failure)
    refute @gh.called?(:clone), "a wrong --key must fail before the StateWriter ever clones"
    refute @gh.called?(:release_exists?), "a wrong --key must fail before the release check"
  end

  def test_record_skips_release_creation_when_already_present
    stub_releases_clone
    @gh.stub_release_exists(REPO, "v#{VERSION}")

    result = new_promote.record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    refute @gh.called?(:create_release), "an existing release must not be recreated"
  end

  def test_record_release_body_picks_ios_notes_for_ios_repo
    stub_releases_clone
    write_notes(ios: "## iOS notes\n", android: "## Android notes\n")

    new_promote.record(**record_args(repo: REPO))

    assert_equal "## iOS notes\n", @gh.release_body(REPO, "v#{VERSION}")
  end

  def test_record_release_body_picks_android_notes_for_client_repo
    android_repo = "xmtplabs/convos-client"
    stub_releases_clone(repos: { android_repo => "source-sha" })
    write_notes(ios: "## iOS notes\n", android: "## Android notes\n")

    new_promote.record(**record_args(repo: android_repo, key: "version-code", value: "77"))

    assert_equal "## Android notes\n", @gh.release_body(android_repo, "v#{VERSION}")
  end

  def test_record_release_body_empty_with_warning_when_notes_file_absent
    stub_releases_clone
    # no write_notes call: .train-promote is empty/absent

    result = new_promote.record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    assert_equal "", @gh.release_body(REPO, "v#{VERSION}")
    assert_match(/warning.*no release notes/i, @out.string)
  end

  def test_record_posts_pr_comment_with_tag_and_version_when_pr_given
    stub_releases_clone

    result = new_promote.record(**record_args(pr_number: 42))

    assert_equal Dry::Monads::Success(true), result
    comments = @gh.pr_comments_for(REPO, 42)
    assert_equal 1, comments.size
    body = comments.first[:body]
    assert_includes body, "v#{VERSION}"
    assert_includes body, "train status #{VERSION}"
    assert_includes body, "https://appstoreconnect.apple.com/apps"
  end

  def test_record_does_not_comment_when_no_pr_given
    stub_releases_clone

    new_promote.record(**record_args)

    assert_empty @gh.pr_comments_for(REPO, 42)
    refute @gh.called?(:pr_comment)
  end

  def test_record_android_comment_links_play_console
    android_repo = "xmtplabs/convos-client"
    stub_releases_clone(repos: { android_repo => "source-sha" })

    new_promote.record(**record_args(repo: android_repo, key: "version-code", value: "77", pr_number: 7))

    comments = @gh.pr_comments_for(android_repo, 7)
    assert_includes comments.first[:body], "https://play.google.com/console"
  end

  # Under dry-run the seam's mutating methods (push/create_release/
  # pr_comment) are still CALLED — that's how Github#mutate! works, logging
  # "[dry-run] would ..." — but none of them may produce an observable
  # state change: no real push (FakeGithub's dry_run branch never fails a
  # push), no release actually recorded, no comment actually appended.
  def test_record_dry_run_makes_zero_mutations
    gh = FakeGithub.new(dry_run: true)
    stub_releases_clone(gh)

    result = Train::Promote.new(github: gh, out: @out).record(**record_args(pr_number: 42))

    assert_equal Dry::Monads::Success(true), result
    assert_nil gh.release_body(REPO, "v#{VERSION}"), "dry-run must not actually record a release"
    assert_empty gh.pr_comments_for(REPO, 42), "dry-run must not actually post a PR comment"
  end

  def test_record_no_manifest_for_version_is_a_hard_failure
    @gh.stub_clone("convos-releases") { |dest| FileUtils.mkdir_p(File.join(dest, "releases")) }

    result = new_promote.record(**record_args)

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/no manifest for #{VERSION}/, result.failure)
  end

  # ---- back-merge (hotfix) ----

  def test_record_on_hotfix_manifest_opens_back_merge_pr_into_dev
    stub_releases_clone(kind: "hotfix")

    result = new_promote.record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    back_merge = @gh.calls_for(:pr_create).find { |c| c.kwargs[:head] == "hotfix/#{VERSION}" }
    refute_nil back_merge, "expected a back-merge pr_create call for hotfix/#{VERSION}"
    assert_equal "dev", back_merge.kwargs[:base]
    assert_equal REPO, back_merge.kwargs[:repo]
    assert_match(/back-merge hotfix #{VERSION}/i, back_merge.kwargs[:title])
    assert_match(/conflict/i, back_merge.kwargs[:body])
  end

  def test_record_on_release_manifest_does_not_open_back_merge_pr
    stub_releases_clone(kind: "release")

    result = new_promote.record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    refute(@gh.calls_for(:pr_create).any? { |c| c.kwargs[:base] == "dev" }, "release-kind manifest must not trigger a back-merge PR")
  end

  # back-merge now runs BEFORE the manifest write and is a HARD gate: a
  # real API failure must fail `record` overall and leave the manifest
  # untouched (no clone-mutate-commit-push ever happens).
  def test_record_back_merge_api_error_is_a_hard_failure_with_no_manifest_write
    stub_releases_clone(kind: "hotfix")
    @gh.fail_pr_create(REPO, message: "simulated back-merge API failure")

    result = new_promote.record(**record_args)

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/back-merge.*#{Regexp.escape(REPO)}/i, result.failure)
    assert_match(/simulated back-merge API failure/, result.failure)
    refute @gh.called?(:push), "a hard back-merge failure must abort before any manifest push"
    refute @gh.called?(:commit), "a hard back-merge failure must abort before any manifest commit"
  end

  # ---- back-merge: branch restored when delete-on-merge removed it ----

  def test_record_restores_deleted_hotfix_branch_before_back_merge
    stub_releases_clone(kind: "hotfix")
    @gh.stub_branch_missing(REPO, "hotfix/#{VERSION}")
    @gh.stub_pr_list(
      repo: REPO, head: "hotfix/#{VERSION}", base: "main", state: "all",
      result: [{ "number" => 40, "url" => "https://x/40", "merged_at" => "2026-07-15T00:00:00Z",
                 "head-sha" => "hotfix-tip-sha" }]
    )

    result = new_promote.record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    restore = @gh.calls_for(:create_ref).first
    refute_nil restore, "the deleted branch must be recreated before the back-merge PR"
    assert_equal "hotfix/#{VERSION}", restore.kwargs[:branch]
    assert_equal "hotfix-tip-sha", restore.kwargs[:sha]
    assert(@gh.calls_for(:pr_create).any? { |c| c.kwargs[:base] == "dev" })
  end

  def test_record_fails_loud_when_deleted_branch_cannot_be_restored
    stub_releases_clone(kind: "hotfix")
    @gh.stub_branch_missing(REPO, "hotfix/#{VERSION}")
    @gh.stub_pr_list(repo: REPO, head: "hotfix/#{VERSION}", base: "main", state: "all", result: [])

    result = new_promote.record(**record_args)

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/restore the branch manually/, result.failure)
    refute @gh.called?(:commit), "an unrestorable back-merge must abort before any manifest write"
  end

  # ---- back-merge tolerances: rerun-safe outcomes still succeed ----

  def test_record_back_merge_already_exists_is_tolerated_as_success
    stub_releases_clone(kind: "hotfix")
    @gh.fail_pr_create(REPO, message: "A pull request already exists for xmtplabs:hotfix/#{VERSION}.")

    result = new_promote.record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    assert @gh.called?(:push), "a tolerated back-merge outcome must still let the manifest write proceed"
  end

  def test_record_back_merge_no_commits_between_is_tolerated_as_success
    stub_releases_clone(kind: "hotfix")
    @gh.fail_pr_create(REPO, message: "No commits between dev and hotfix/#{VERSION}")

    result = new_promote.record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    assert @gh.called?(:push), "a tolerated back-merge outcome must still let the manifest write proceed"
  end

  private

  def write_manifest_fixture_into(dest, repo: REPO,
                                  rc_entries: [{ "sha" => HEAD_SHA, "run" => "https://run/1", "build-number" => 100 }])
    mdir = File.join(dest, "releases", VERSION)
    FileUtils.mkdir_p(mdir)
    mfile = File.join(mdir, "manifest.yml")
    Train::Manifest.init(
      mfile, version: VERSION, kind: "release", cut_date: "2026-07-16",
      repos: { repo => "source-sha" }
    )
    data = Train::Manifest.read(mfile)
    data["repos"][repo]["rc"] = rc_entries
    Train::Manifest.write(mfile, data)
    File.write(File.join(mdir, "ios.md"), "## Features\n- ios note\n")
    File.write(File.join(mdir, "android.md"), "## Features\n- android note\n")
    File.write(File.join(mdir, "submission-notes.md"), "# Submission notes\n")
  end
end
