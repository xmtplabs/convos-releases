# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "pathname"
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

  def test_prepare_stages_store_rendered_twins_alongside_the_markdown
    write_manifest_fixture
    stub_matching_trees
    @gh.stub_tag_sha("v#{VERSION}", "")

    result = new_promote.prepare(**base_args)

    assert_instance_of Dry::Monads::Result::Success, result
    notes_dir = File.join(@app_dir, ".train-promote")
    # fixture ios.md is "## Features\n- ios note\n"
    assert_equal "Features:\n• ios note", File.read(File.join(notes_dir, "ios.store.txt"))
    assert File.exist?(File.join(notes_dir, "android.store.txt"))
    # reviewer notes render in URL-preserving mode
    submission = File.read(File.join(notes_dir, "submission.store.txt"), encoding: Encoding::UTF_8)
    assert_includes submission, "env (https://test.example)"
  end

  def test_prepare_fails_before_tag_when_platform_notes_are_missing
    @gh.stub_clone("convos-releases") do |dest|
      mdir = File.join(dest, "releases", VERSION)
      FileUtils.mkdir_p(mdir)
      Train::Manifest.init(
        File.join(mdir, "manifest.yml"), version: VERSION, kind: "release", cut_date: "2026-07-16",
        repos: { REPO => "source-sha" }
      )
      data = Train::Manifest.read(File.join(mdir, "manifest.yml"))
      data["repos"][REPO]["rc"] = [{ "sha" => HEAD_SHA, "run" => "https://run/1", "build-number" => 100 }]
      Train::Manifest.write(File.join(mdir, "manifest.yml"), data)
      # no ios.md, no submission-notes.md
    end
    stub_matching_trees
    @gh.stub_tag_sha("v#{VERSION}", "")

    result = new_promote.prepare(**base_args)

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/missing ios\.md, submission-notes\.md/, result.failure)
    refute @gh.called?(:push), "missing notes must stop promotion before the tag is pushed"
  end

  def test_prepare_fails_when_android_notes_render_over_the_play_limit
    android_repo = "xmtplabs/convos-client"
    @gh.stub_clone("convos-releases") do |dest|
      mdir = File.join(dest, "releases", VERSION)
      FileUtils.mkdir_p(mdir)
      Train::Manifest.init(
        File.join(mdir, "manifest.yml"), version: VERSION, kind: "release", cut_date: "2026-07-16",
        repos: { android_repo => "source-sha" }
      )
      data = Train::Manifest.read(File.join(mdir, "manifest.yml"))
      data["repos"][android_repo]["rc"] = [{ "sha" => HEAD_SHA, "run" => "https://run/1", "version-code" => 77 }]
      Train::Manifest.write(File.join(mdir, "manifest.yml"), data)

      File.write(File.join(mdir, "android.md"), "- #{"x" * 600}\n")
      File.write(File.join(mdir, "submission-notes.md"), "# Submission notes\n")
    end
    stub_matching_trees
    @gh.stub_tag_sha("v#{VERSION}", "")

    result = new_promote.prepare(**base_args.merge(repo: android_repo))

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/render to \d+ chars \(Play limit 500\)/, result.failure)
    refute @gh.called?(:push), "oversized notes must stop promotion before the tag is pushed"
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
    # Every back-merge (both kinds) now builds/validates the backmerge branch
    # from app_dir: it needs a repo-identity origin, a resolvable dev, a
    # version file, and a clean-version-file answer from dirty?. Default to
    # the safe path: every ref reads the same planted version -> no reset.
    app = File.basename(@app_dir)
    gh.stub_remote_url(app, "https://github.com/#{repos.keys.first}.git")
    gh.set_dirty(false)
    plant_pbxproj(@app_dir, VERSION)
    if kind == "release"
      # Default the release gate to the common "no divergence" path: dev and
      # release resolve to the SAME sha, so the dev..tip range is empty -> no
      # PR. Divergence tests override via stub_release_divergence.
      gh.stub_ls_remote(app, "refs/heads/dev", "samesha")
      gh.stub_ls_remote(app, "refs/heads/release/#{VERSION}", "samesha")
      gh.stub_commit_authors(app, "samesha..samesha", [])
    else
      gh.stub_ls_remote(app, "refs/heads/dev", "devsha")
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
    back_merge = @gh.calls_for(:pr_create).find { |c| c.kwargs[:head] == "backmerge/#{VERSION}" }
    refute_nil back_merge, "expected a back-merge pr_create call from backmerge/#{VERSION}"
    assert_equal "dev", back_merge.kwargs[:base]
    assert_equal REPO, back_merge.kwargs[:repo]
    assert_match(/back-merge hotfix #{VERSION}/i, back_merge.kwargs[:title])
    assert_match(/conflict/i, back_merge.kwargs[:body])
    # The body must still name the source branch being carried into dev.
    assert_match(%r{hotfix/#{VERSION}}, back_merge.kwargs[:body])
  end

  # A squash strips the ancestry the back-merge carries, so record arms
  # auto-merge pinned to MERGE and re-arms when the PR already exists.
  def test_record_on_hotfix_back_merge_arms_auto_merge_with_a_true_merge
    stub_releases_clone(kind: "hotfix")

    result = new_promote.record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    arm = @gh.calls_for(:pr_merge_auto).find { |c| c.kwargs[:methods] == ["MERGE"] }
    refute_nil arm, "expected auto-merge to be armed on the back-merge PR"
    # The fresh-create path arms by the created PR's own number, never by a
    # branch lookup that could race or resolve a same-head sibling PR.
    assert_kind_of Integer, arm.kwargs[:head_or_number]
    assert_equal "dev", arm.kwargs[:base]
  end

  def test_record_back_merge_pr_already_exists_still_arms_auto_merge
    stub_releases_clone(kind: "hotfix")
    @gh.fail_pr_create(REPO, message: "A pull request already exists for backmerge/#{VERSION}.")

    result = new_promote.record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    arm = @gh.calls_for(:pr_merge_auto).find { |c| c.kwargs[:head_or_number] == "backmerge/#{VERSION}" }
    refute_nil arm, "an existing back-merge PR must still get auto-merge re-armed"
    assert_equal ["MERGE"], arm.kwargs[:methods]
    # Branch resolution must pin base dev — this head also has a PR to main.
    assert_equal "dev", arm.kwargs[:base]
  end

  def test_record_back_merge_auto_merge_arm_failure_is_a_warning_not_a_failure
    stub_releases_clone(kind: "hotfix")
    # The fake's pr_create numbers count up from 101; the back-merge PR is
    # this record run's first create, so its arm call targets 101.
    @gh.stub_pr_merge_auto_result(REPO, 101, false)

    result = new_promote.record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    assert_match(/never squash/, @out.string)
  end

  # Model DISTINCT dev and release-tip shas so the divergence range is a real
  # "devsha..releasesha"; commit_authors on that range yields `authors`.
  def stub_release_divergence(authors:, dev_sha: "devsha", release_tip: "releasesha")
    app = File.basename(@app_dir)
    @gh.stub_ls_remote(app, "refs/heads/dev", dev_sha)
    @gh.stub_ls_remote(app, "refs/heads/release/#{VERSION}", release_tip)
    @gh.stub_commit_authors(app, "#{dev_sha}..#{release_tip}", authors)
  end

  def test_record_on_release_manifest_with_no_divergence_does_not_open_back_merge_pr
    stub_releases_clone(kind: "release")
    # Empty dev..tip range (branch untouched since cut): commit_authors -> [] -> no PR.
    stub_release_divergence(authors: [])

    result = new_promote.record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    refute(@gh.calls_for(:pr_create).any? { |c| c.kwargs[:base] == "dev" },
           "release with no divergence must not trigger a back-merge PR")
  end

  def test_record_on_release_with_human_divergence_opens_back_merge_pr
    stub_releases_clone(kind: "release")
    stub_release_divergence(authors: ["human@example.com"])

    result = new_promote.record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    back_merge = @gh.calls_for(:pr_create).find { |c| c.kwargs[:head] == "backmerge/#{VERSION}" }
    refute_nil back_merge, "expected a backmerge/#{VERSION} -> dev back-merge PR"
    assert_equal "dev", back_merge.kwargs[:base]
    assert_equal REPO, back_merge.kwargs[:repo]
    assert_match(/back-merge release #{VERSION}/i, back_merge.kwargs[:title])
    # The range actually queried must be the two DISTINCT captured shas, in order.
    authors_call = @gh.calls_for(:commit_authors).last
    assert_equal "devsha..releasesha", authors_call.args[1]
  end

  def test_record_on_release_with_empty_author_email_still_opens_back_merge_pr
    stub_releases_clone(kind: "release")
    # A commit whose %ae is blank is NOT the bot identity -> must force a PR.
    stub_release_divergence(authors: [""])

    result = new_promote.record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    refute_nil(@gh.calls_for(:pr_create).find { |c| c.kwargs[:head] == "backmerge/#{VERSION}" },
               "an empty-author commit must not be treated as the bot")
  end

  def test_record_on_release_with_only_bot_divergence_does_not_open_back_merge_pr
    stub_releases_clone(kind: "release")
    stub_release_divergence(authors: ["convos-conductor[bot]@users.noreply.github.com"])

    result = new_promote.record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    refute(@gh.calls_for(:pr_create).any? { |c| c.kwargs[:base] == "dev" },
           "bot-only divergence must not trigger a back-merge PR")
  end

  def test_record_release_back_merge_check_git_failure_is_a_hard_failure
    stub_releases_clone(kind: "release")
    app = File.basename(@app_dir)
    # Diverge (distinct shas) so the check reaches commit_authors, then fail it —
    # a regression to a non-raising author check must fail loud here, not skip.
    @gh.stub_ls_remote(app, "refs/heads/dev", "devsha")
    @gh.stub_ls_remote(app, "refs/heads/release/#{VERSION}", "releasesha")
    @gh.fail_commit_authors(app, message: "simulated log failure")

    result = new_promote.record(**record_args)

    assert result.failure?, "a git failure in the divergence check must abort record"
    assert_match(/release back-merge check failed/, result.failure)
    refute(@gh.calls_for(:pr_create).any? { |c| c.kwargs[:base] == "dev" })
    # Manifest promotion must NOT have been recorded (fail before the write).
    refute(@gh.calls_for(:commit).any?, "manifest must be untouched on a hard check failure")
  end

  def test_record_on_release_with_deleted_branch_uses_merged_pr_head_sha
    stub_releases_clone(kind: "release")
    app = File.basename(@app_dir)
    # Branch deleted on merge: ls_remote for it returns "" -> fall back to the
    # merged release PR's head-sha, and still detect the human divergence.
    @gh.stub_ls_remote(app, "refs/heads/dev", "devsha")
    @gh.stub_ls_remote(app, "refs/heads/release/#{VERSION}", "")
    @gh.stub_pr_list(repo: REPO, head: "release/#{VERSION}", base: "main", state: "all",
                     result: [{ "merged_at" => "2026-07-16T00:00:00Z", "head-sha" => "mergedtip" }])
    @gh.stub_commit_authors(app, "devsha..mergedtip", ["human@example.com"])

    result = new_promote.record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    refute_nil(@gh.calls_for(:pr_create).find { |c| c.kwargs[:head] == "backmerge/#{VERSION}" },
               "a deleted-but-diverged release branch must still back-merge via its merged PR tip")
  end

  def test_record_on_release_with_deleted_branch_picks_last_merged_pr
    stub_releases_clone(kind: "release")
    app = File.basename(@app_dir)
    @gh.stub_ls_remote(app, "refs/heads/dev", "devsha")
    @gh.stub_ls_remote(app, "refs/heads/release/#{VERSION}", "")
    # GitHub lists newest-CREATED first; the LAST-merged (max merged_at) is the
    # authoritative tip even when it was created earlier.
    @gh.stub_pr_list(repo: REPO, head: "release/#{VERSION}", base: "main", state: "all", result: [
                       { "merged_at" => "2026-07-15T00:00:00Z", "head-sha" => "newer-created-older-merge" },
                       { "merged_at" => "2026-07-18T00:00:00Z", "head-sha" => "last-merged-tip" }
                     ])
    @gh.stub_commit_authors(app, "devsha..last-merged-tip", ["human@example.com"])

    result = new_promote.record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    # The range queried must use the LAST-merged PR's head-sha.
    assert(@gh.calls_for(:commit_authors).any? { |c| c.args[1] == "devsha..last-merged-tip" },
           "must resolve the tip from the last-merged PR, not the newest-created")
  end

  def test_record_on_release_with_missing_dev_fails_loud
    stub_releases_clone(kind: "release")
    app = File.basename(@app_dir)
    @gh.stub_ls_remote(app, "refs/heads/dev", "") # dev gone/renamed — an anomaly

    result = new_promote.record(**record_args)

    assert result.failure?, "a missing dev branch must abort record, not silently skip"
    assert_match(/no dev branch/, result.failure)
    refute(@gh.calls_for(:commit).any?, "manifest must be untouched")
  end

  def test_record_on_release_with_mismatched_app_dir_fails_loud
    stub_releases_clone(kind: "release")
    app = File.basename(@app_dir)
    # Checkout is a sibling repo, not the one being promoted.
    @gh.stub_remote_url(app, "https://github.com/xmtplabs/convos-ios-fork.git")

    result = new_promote.record(**record_args)

    assert result.failure?, "a checkout that isn't the promoted repo must abort record"
    assert_match(/is not a checkout of #{Regexp.escape(REPO)}/, result.failure)
    refute(@gh.calls_for(:pr_create).any? { |c| c.kwargs[:base] == "dev" })
  end

  def test_record_on_release_rejects_impostor_and_foreign_origins
    # Each has the right owner/name path but is NOT github.com's repo, so the
    # checkout-identity guard must reject it and abort record. A fresh FakeGithub
    # per origin keeps the recorded pr_create calls isolated.
    [
      "https://gitlab.com/#{REPO}.git",              # foreign host
      "https://notgithub.com/#{REPO}.git",           # host with github.com as a suffix
      "https://gitlab.com/github.com/#{REPO}.git"    # github.com embedded mid-path
    ].each do |origin|
      gh = FakeGithub.new
      stub_releases_clone(gh, kind: "release")
      gh.stub_remote_url(File.basename(@app_dir), origin)

      result = new_promote(gh).record(**record_args)

      assert result.failure?, "origin #{origin} must abort record"
      assert_match(/is not a checkout of #{Regexp.escape(REPO)}/, result.failure)
      refute(gh.calls_for(:pr_create).any? { |c| c.kwargs[:base] == "dev" }, "no PR for #{origin}")
    end
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

  IOS_VERSION_REL_PATH = "Convos.xcodeproj/project.pbxproj"

  # Plants a minimal pbxproj so the back-merge build's Versions.read/bump
  # operate on real file content; the fake's checkouts swap it per ref via
  # stub_checkout_content.
  def plant_pbxproj(dir, version)
    path = File.join(dir, IOS_VERSION_REL_PATH)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "\t\t\t\tMARKETING_VERSION = #{version};\n")
  end

  # Wires the fresh-build back-merge path for a hotfix record: backmerge
  # branch absent on origin, per-ref version contents materialized by the
  # fake's checkouts. tip_ref is the sha the build checks out (defaults to
  # the live hotfix tip the fake's branch_sha reports). Assumes
  # stub_releases_clone(kind: "hotfix") already ran.
  def stub_backmerge_build(dev_version: "2.1.0", tip_version: "2.1.0", tip_ref: "sha-hotfix/#{VERSION}")
    app = File.basename(@app_dir)
    @gh.stub_branch_missing(REPO, "backmerge/#{VERSION}")
    plant_pbxproj(@app_dir, tip_version)
    @gh.stub_checkout_content(app, "devsha") { |d| plant_pbxproj(d, dev_version) }
    @gh.stub_checkout_content(app, tip_ref) { |d| plant_pbxproj(d, tip_version) }
  end

  # ---- back-merge: the PR head is backmerge/<v>, never release/hotfix ----

  # The regression lock for the 2.5.0 ghost RC: the app repos' RC-upload
  # workflows trigger on every push to release/<v> and hotfix/<v>, and
  # creating a branch fires a real push event — so recreating a
  # merge-deleted source branch uploaded a NEW store build of the version
  # that had just promoted, displacing the recorded RC. record must never
  # write those refs; the PR opens from a dedicated backmerge/<v> branch.
  def test_record_never_recreates_release_or_hotfix_branches
    stub_releases_clone(kind: "hotfix")
    stub_backmerge_build(tip_ref: "hotfix-tip-sha")
    @gh.stub_branch_missing(REPO, "hotfix/#{VERSION}")
    @gh.stub_pr_list(repo: REPO, head: "hotfix/#{VERSION}", base: "main", state: "all",
                     result: [{ "merged_at" => "2026-07-15T00:00:00Z", "head-sha" => "hotfix-tip-sha" }])

    result = new_promote.record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    pushed = @gh.calls_for(:push).select { |c| c.args[1].to_s.match?(%r{:refs/heads/(release|hotfix)/}) }
    assert_empty pushed, "record must never push to an RC-triggering branch"
    built = @gh.calls_for(:checkout_branch).select { |c| c.args[1].to_s.start_with?("release/", "hotfix/") }
    assert_empty built, "record must never build a local release/hotfix branch"
    assert(@gh.calls_for(:pr_create).all? { |c| c.kwargs[:head] == "backmerge/#{VERSION}" })
  end

  def test_record_builds_backmerge_branch_at_the_live_source_tip
    stub_releases_clone(kind: "hotfix")
    stub_backmerge_build

    result = new_promote.record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    build = @gh.calls_for(:checkout).find { |c| c.args[1] == "sha-hotfix/#{VERSION}" }
    refute_nil build, "the build must check out the source tip (detached)"
    push = @gh.calls_for(:push).find { |c| c.args[1] == "HEAD:refs/heads/backmerge/#{VERSION}" }
    refute_nil push, "the built branch must be pushed in one step — origin never sees an unreset head"
    # Detached build: no local branch is ever created or reset, so no local
    # branch state can be clobbered.
    refute @gh.called?(:checkout_branch), "the build must not create or reset a local branch"
  end

  def test_record_backmerge_branch_falls_back_to_merged_pr_tip_when_source_deleted
    stub_releases_clone(kind: "hotfix")
    stub_backmerge_build(tip_ref: "hotfix-tip-sha")
    @gh.stub_branch_missing(REPO, "hotfix/#{VERSION}")
    @gh.stub_pr_list(
      repo: REPO, head: "hotfix/#{VERSION}", base: "main", state: "all",
      result: [{ "number" => 40, "url" => "https://x/40", "merged_at" => "2026-07-15T00:00:00Z",
                 "head-sha" => "hotfix-tip-sha" }]
    )

    result = new_promote.record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    build = @gh.calls_for(:checkout).find { |c| c.args[1] == "hotfix-tip-sha" }
    refute_nil build, "the build must check out the merged PR's recorded tip"
    assert(@gh.calls_for(:pr_create).any? { |c| c.kwargs[:base] == "dev" })
  end

  # A rerun (or a died run) may find backmerge/<v> already on origin — with
  # a human's conflict-resolution pushes on it. Its commits must never be
  # discarded; a SAFE branch (version already matches dev) needs no push.
  def test_record_existing_safe_backmerge_branch_is_not_pushed
    stub_releases_clone(kind: "hotfix")
    # Default fake state: backmerge/<v> exists; every ref reads the planted
    # version, so the branch already matches dev.

    result = new_promote.record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    refute(@gh.calls_for(:push).any? { |c| c.args[1].to_s.include?("backmerge/") },
           "a safe existing backmerge branch must not be re-pushed")
    assert(@gh.calls_for(:pr_create).any? { |c| c.kwargs[:head] == "backmerge/#{VERSION}" })
  end

  # An existing backmerge branch may be UNSAFE: the pre-#43 train created it
  # at the raw source tip, so it can still carry the pure version downgrade.
  # The build must validate it and APPEND a reset commit (fast-forward — a
  # human's conflict-resolution commits survive) rather than trusting it.
  def test_record_appends_version_reset_to_an_unsafe_existing_backmerge_branch
    stub_releases_clone(kind: "hotfix")
    app = File.basename(@app_dir)
    @gh.stub_checkout_content(app, "devsha") { |d| plant_pbxproj(d, "2.2.0") }
    @gh.stub_checkout_content(app, "sha-backmerge/#{VERSION}") { |d| plant_pbxproj(d, "2.1.1") }

    result = new_promote.record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    build = @gh.calls_for(:checkout).find { |c| c.args[1] == "sha-backmerge/#{VERSION}" }
    refute_nil build, "the existing branch's own tip must be checked out (append-only)"
    reset = @gh.calls_for(:commit).find { |c| c.args[1].include?("keep dev's version 2.2.0") }
    refute_nil reset, "an unsafe existing branch must get a reset commit appended"
    refute_nil(@gh.calls_for(:push).find { |c| c.args[1] == "HEAD:refs/heads/backmerge/#{VERSION}" },
               "the appended reset must be pushed (fast-forward)")
  end

  # ---- back-merge: version files pre-resolved to dev's version ----

  # The 2.5.0 scenario (convos-ios#1416): everything on the release line was
  # already in dev except version churn, so the back-merge PR was a pure
  # version downgrade that a clean auto-merge would have applied to dev.
  # The build must reset the backmerge branch's version files to dev's
  # version so the PR can never regress dev, whatever happened on the
  # source branch.
  def test_record_resets_backmerge_versions_to_devs_version
    stub_releases_clone(kind: "hotfix")
    stub_backmerge_build(dev_version: "2.2.0", tip_version: "2.1.1")

    result = new_promote.record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    reset = @gh.calls_for(:commit).find { |c| c.args[1].include?("keep dev's version 2.2.0") }
    refute_nil reset, "expected a version-reset commit on the backmerge branch"
    # Path-scoped commit, never an index sweep: a dirty manual checkout's
    # staged files must not be able to ride along into a pushed commit.
    assert_equal [File.join(@app_dir, IOS_VERSION_REL_PATH)], reset.kwargs[:paths]
    refute reset.kwargs[:all], "the reset commit must never be a commit -a sweep"
    # The reset really ran (real Versions.bump against the working tree).
    assert_equal "2.2.0", Train::Versions.read(@app_dir)
  end

  def test_record_skips_version_reset_when_tip_matches_dev
    stub_releases_clone(kind: "hotfix")
    stub_backmerge_build(dev_version: "2.1.0", tip_version: "2.1.0")

    result = new_promote.record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    refute(@gh.calls_for(:commit).any? { |c| c.args[1].include?("keep dev's version") },
           "no reset commit when the tip already matches dev")
    refute_nil(@gh.calls_for(:push).find { |c| c.args[1] == "HEAD:refs/heads/backmerge/#{VERSION}" },
               "the branch must still be pushed")
  end

  # The build rewrites and commits a file in the caller's checkout, so a
  # version file with pre-existing local edits must abort rather than push
  # someone's uncommitted work to the back-merge head.
  def test_record_refuses_to_build_from_a_dirty_version_file
    stub_releases_clone(kind: "hotfix")
    stub_backmerge_build(dev_version: "2.2.0", tip_version: "2.1.1")
    @gh.set_dirty(true)

    result = new_promote.record(**record_args)

    assert result.failure?, "a dirty version file must abort the back-merge build"
    assert_match(/uncommitted changes/, result.failure)
    refute @gh.called?(:commit), "manifest must be untouched"
    refute(@gh.calls_for(:push).any? { |c| c.args[1].to_s.include?("backmerge/") })
  end

  # Dry-run must not leave the caller's checkout rewritten or detached: the
  # local build is skipped entirely, not merely gated at the push.
  def test_record_dry_run_does_not_touch_the_local_checkout
    gh = FakeGithub.new(dry_run: true)
    stub_releases_clone(gh, kind: "hotfix")
    gh.stub_branch_missing(REPO, "backmerge/#{VERSION}")
    plant_pbxproj(@app_dir, "2.1.1")

    result = new_promote(gh).record(**record_args)

    assert_equal Dry::Monads::Success(true), result
    refute gh.called?(:checkout), "dry-run must not check out anything in app_dir"
    # The manifest write's own commit still runs (mutate!-gated); nothing
    # may be committed in the APP checkout.
    refute(gh.calls_for(:commit).any? { |c| c.args[0] == @app_dir },
           "dry-run must not commit in app_dir")
    assert_equal "2.1.1", Train::Versions.read(@app_dir), "dry-run must leave the version file alone"
    assert_match(/\[dry-run\]/, @out.string)
  end

  # --app-dir is passed through verbatim, so a relative path must still
  # produce a git-usable staged path: `git -C <dir>` resolves pathspecs from
  # inside <dir>, where a repo-root-prefixed relative path would miss.
  def test_record_stages_an_absolute_version_path_for_a_relative_app_dir
    stub_releases_clone(kind: "hotfix")
    stub_backmerge_build(dev_version: "2.2.0", tip_version: "2.1.1")
    relative = Pathname.new(File.realpath(@app_dir)).relative_path_from(Pathname.pwd).to_s

    result = new_promote.record(**record_args(app_dir: relative))

    assert_equal Dry::Monads::Success(true), result
    reset = @gh.calls_for(:commit).find { |c| c.args[1].include?("keep dev's version") }
    refute_nil reset
    assert_equal [File.join(File.realpath(@app_dir), IOS_VERSION_REL_PATH)], reset.kwargs[:paths]
  end

  # record's contract is a Result, not an exception: a filesystem failure in
  # the version surgery must abort as a Failure before the manifest write.
  def test_record_filesystem_failure_during_version_surgery_is_a_hard_failure
    stub_releases_clone(kind: "hotfix")
    stub_backmerge_build(dev_version: "2.2.0", tip_version: "2.1.1")
    app = File.basename(@app_dir)
    # The version file vanishes between the checkout and the read.
    @gh.stub_checkout_content(app, "devsha") { |d| FileUtils.rm_rf(File.join(d, "Convos.xcodeproj")) }

    result = new_promote.record(**record_args)

    assert result.failure?, "a filesystem failure must abort record as a Failure"
    assert_match(/back-merge|version/i, result.failure)
    refute @gh.called?(:commit), "manifest must be untouched"
  end

  def test_record_version_reset_failure_is_a_hard_failure_before_the_manifest_write
    stub_releases_clone(kind: "hotfix")
    stub_backmerge_build(dev_version: "2.2.0", tip_version: "2.1.1")
    app = File.basename(@app_dir)
    # dev's checkout carries a split version — Versions.read must fail loud
    # and abort record before anything is recorded.
    @gh.stub_checkout_content(app, "devsha") do |d|
      path = File.join(d, IOS_VERSION_REL_PATH)
      File.write(path, "\tMARKETING_VERSION = 2.2.0;\n\tMARKETING_VERSION = 2.3.0;\n")
    end

    result = new_promote.record(**record_args)

    assert result.failure?, "an unreadable dev version must abort record"
    assert_match(/inconsistent versions/, result.failure)
    refute(@gh.calls_for(:pr_create).any? { |c| c.kwargs[:base] == "dev" })
    refute @gh.called?(:commit), "manifest must be untouched"
  end

  def test_record_fails_loud_when_the_backmerge_tip_cannot_be_resolved
    stub_releases_clone(kind: "hotfix")
    @gh.stub_branch_missing(REPO, "backmerge/#{VERSION}")
    @gh.stub_branch_missing(REPO, "hotfix/#{VERSION}")
    @gh.stub_pr_list(repo: REPO, head: "hotfix/#{VERSION}", base: "main", state: "all", result: [])

    result = new_promote.record(**record_args)

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(%r{create backmerge/#{VERSION}.*manually}, result.failure)
    refute @gh.called?(:commit), "an unresolvable back-merge tip must abort before any manifest write"
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
    File.write(File.join(mdir, "submission-notes.md"), "# Submission notes\n\n[env](https://test.example)\n")
  end
end
