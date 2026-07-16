# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "dry/monads"
require "train/hotfix"
require_relative "support/fake_github"

class HotfixTest < Minitest::Test
  IOS = "xmtplabs/convos-ios"
  ANDROID = "xmtplabs/convos-client"
  BASE_TAG = "v2.1.0"
  VERSION = "2.1.1"

  def setup
    @releases_dir = Dir.mktmpdir("train-hotfix-test-")
    FileUtils.mkdir_p(File.join(@releases_dir, "releases"))
    @gh = FakeGithub.new
    stub_repo_clones
    @out = StringIO.new
    @err = StringIO.new
  end

  def teardown
    FileUtils.remove_entry(@releases_dir)
  end

  def stub_repo_clones(latest_tag: BASE_TAG)
    @gh.stub_clone("convos-ios") { |dest| write_ios_fixture(dest, "2.1.0") }
    @gh.stub_clone("convos-client") { |dest| write_android_fixture(dest, "2.1.0") }
    @gh.stub_latest_tag("convos-ios", latest_tag)
    @gh.stub_latest_tag("convos-client", latest_tag)
    @gh.stub_rev_parse("convos-ios", "#{BASE_TAG}^{commit}", "ios-tag-sha")
    @gh.stub_rev_parse("convos-client", "#{BASE_TAG}^{commit}", "android-tag-sha")
  end

  def write_android_fixture(dest, version)
    FileUtils.mkdir_p(File.join(dest, "android"))
    File.write(File.join(dest, "android", "gradle.properties"), "VERSION_NAME=#{version}\n")
  end

  def write_ios_fixture(dest, version)
    FileUtils.mkdir_p(File.join(dest, "Convos.xcodeproj"))
    File.write(
      File.join(dest, "Convos.xcodeproj", "project.pbxproj"),
      "MARKETING_VERSION = #{version};\nMARKETING_VERSION = #{version};\n"
    )
  end

  def new_hotfix(gh = @gh)
    Train::Hotfix.new(github: gh, releases_dir: @releases_dir, out: @out, err: @err)
  end

  def manifest_file(version = VERSION)
    File.join(@releases_dir, "releases", version, "manifest.yml")
  end

  # ---- happy path ----

  def test_happy_path_both_repos
    result = new_hotfix.run(base_tag: BASE_TAG)

    assert_equal Dry::Monads::Success(:hotfixed), result

    data = Train::Manifest.read(manifest_file)
    assert_equal VERSION, data["version"]
    assert_equal "hotfix", data["kind"]
    assert_equal "ios-tag-sha", data["repos"][IOS]["source-sha"]
    assert_equal "android-tag-sha", data["repos"][ANDROID]["source-sha"]
    assert_equal "branched", data["repos"][IOS]["status"]
    assert_equal "branched", data["repos"][ANDROID]["status"]
    assert_equal "hotfix/#{VERSION}", data["repos"][IOS]["release-branch"]

    # branches pushed with bump commit: checkout_branch/commit/push sequence
    # per repo, checkout_branch AT the tag's sha.
    checkout_calls = @gh.calls_for(:checkout_branch)
    ios_checkout = checkout_calls.find { |c| c.args[0].end_with?("/convos-ios") }
    assert_equal ["hotfix/#{VERSION}", "ios-tag-sha"], ios_checkout.args[1..2]

    push_calls = @gh.calls_for(:push).select { |c| c.args[1] == "hotfix/#{VERSION}" }
    assert_equal 2, push_calls.size

    commit_messages = @gh.calls_for(:commit).map { |c| c.args[1] }
    assert(commit_messages.any? { |m| m.include?("hotfix bump to #{VERSION}") })

    # PRs created hotfix/<version> -> main.
    pr_titles = @gh.calls_for(:pr_create).map { |c| c.kwargs[:title] }
    assert_includes pr_titles, "Hotfix #{VERSION}"
    pr_bases = @gh.calls_for(:pr_create).map { |c| c.kwargs[:base] }
    assert(pr_bases.all? { |b| b == "main" })

    # notes seeded as a describe-the-fix template — NOT from dev PRs, which
    # are not on the hotfix branch.
    refute @gh.called?(:merged_prs_since), "hotfix notes must not be seeded from dev PR history"
    ios_notes = File.read(File.join(@releases_dir, "releases", VERSION, "ios.md"))
    assert_match(/Hotfix from #{BASE_TAG}/, ios_notes)
    assert_match(/Describe the fix/, ios_notes)
    assert File.exist?(File.join(@releases_dir, "releases", VERSION, "android.md"))
    assert File.exist?(File.join(@releases_dir, "releases", VERSION, "submission-notes.md"))
  end

  # ---- base-tag format ----

  def test_malformed_base_tag_is_a_failure_before_any_clone
    %w[v2.1 2.1.0 v2.1.0.5 v2.1.x].each do |bad|
      result = new_hotfix.run(base_tag: bad)

      assert_instance_of Dry::Monads::Result::Failure, result
      assert_match(/--base-tag must look like vX\.Y\.Z, got '#{Regexp.escape(bad)}'/, result.failure)
    end
    refute @gh.called?(:clone), "a malformed base-tag must fail before touching any repo"
  end

  # ---- base-tag-not-latest ----

  def test_base_tag_not_latest_is_a_failure_with_zero_mutations
    @gh.stub_latest_tag("convos-ios", "v2.1.5") # a newer tag exists

    result = new_hotfix.run(base_tag: BASE_TAG)

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/v2\.1\.0 is not the latest tag on xmtplabs\/convos-ios \(latest: v2\.1\.5\)/, result.failure)

    refute Dir.exist?(File.join(@releases_dir, "releases", VERSION))
    %i[add commit push pr_create checkout_branch].each do |m|
      refute @gh.called?(m), "#{m} must not be called when the base-tag guard fails"
    end
  end

  # ---- only_repo filter ----

  def test_only_repo_filter_produces_single_repo_manifest
    result = new_hotfix.run(base_tag: BASE_TAG, only_repo: IOS)

    assert_equal Dry::Monads::Success(:hotfixed), result

    data = Train::Manifest.read(manifest_file)
    assert_equal [IOS], data["repos"].keys

    # only convos-ios cloned/branched.
    clone_urls = @gh.calls_for(:clone).map { |c| c.args[0] }
    refute(clone_urls.any? { |u| u.include?("convos-client") })

    assert File.exist?(File.join(@releases_dir, "releases", VERSION, "ios.md"))
    # submission-notes.md still written from whichever platform file exists.
    assert File.exist?(File.join(@releases_dir, "releases", VERSION, "submission-notes.md"))
  end

  def test_invalid_only_repo_is_a_failure
    result = new_hotfix.run(base_tag: BASE_TAG, only_repo: "xmtplabs/some-other-repo")

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/--repo must be one of/, result.failure)
    refute @gh.called?(:clone)
  end

  # ---- existing manifest: reconcile mode ----

  def existing_manifest(kind: "hotfix", repos: { IOS => "ios-tag-sha", ANDROID => "android-tag-sha" })
    mdir = File.join(@releases_dir, "releases", VERSION)
    FileUtils.mkdir_p(mdir)
    Train::Manifest.init(
      File.join(mdir, "manifest.yml"), version: VERSION, kind: kind, cut_date: "2026-07-10",
      repos: repos
    )
  end

  def test_kind_release_manifest_at_same_version_is_a_failure
    existing_manifest(kind: "release")

    result = new_hotfix.run(base_tag: BASE_TAG)

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/manifest already exists for #{VERSION} with kind "release"/, result.failure)
    refute @gh.called?(:checkout_branch), "a kind mismatch must not touch any repo"
  end

  def test_mismatched_source_sha_is_a_failure_naming_both
    # manifest recorded a DIFFERENT sha than what the tag now resolves to —
    # base_tag must have moved (a new tag pushed) between the first attempt
    # and this rerun.
    existing_manifest(repos: { IOS => "stale-ios-sha", ANDROID => "android-tag-sha" })

    result = new_hotfix.run(base_tag: BASE_TAG)

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/source-sha mismatch/, result.failure)
    assert_match(/#{Regexp.escape(IOS)}: manifest has "stale-ios-sha", tag now resolves to "ios-tag-sha"/, result.failure)
    refute @gh.called?(:checkout_branch), "a source-sha mismatch must not touch any repo"
  end

  def test_existing_branch_not_containing_tag_sha_is_a_failure
    existing_manifest
    # hotfix/<version> exists on origin but its tip does NOT contain the
    # captured tag sha — a pre-created or force-updated branch, not ours.
    @gh.stub_ls_remote("convos-ios", "refs/heads/hotfix/#{VERSION}", "foreign-tip")
    @gh.stub_not_ancestor("convos-ios")

    result = new_hotfix.run(base_tag: BASE_TAG)

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/hotfix\/#{VERSION} exists but ios-tag-sha was not confirmed reachable from its tip foreign-tip/, result.failure)
    ios_pr_creates = @gh.calls_for(:pr_create).select { |c| c.kwargs[:repo] == IOS }
    assert_empty ios_pr_creates, "a foreign branch must not get a PR opened for it"

    # Pin argument order — "is the TAG SHA an ancestor of the TIP", never
    # the reverse (the fake ignores the args, so this is the only guard).
    call = @gh.calls_for(:ancestor?).first
    assert_equal %w[ios-tag-sha foreign-tip], call.args[1..2]
  end

  def test_versions_error_is_a_per_repo_failure_not_a_crash
    # ios clone is missing its version file — Versions.bump raises
    # Versions::Error, which must fold into that repo's Failure while the
    # other repo still completes.
    @gh.stub_clone("convos-ios") { |dest| FileUtils.mkdir_p(dest) }

    result = new_hotfix.run(base_tag: BASE_TAG)

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/#{Regexp.escape(IOS)}: Train::Versions::Error/, result.failure)

    data = Train::Manifest.read(manifest_file)
    assert_equal "branched", data["repos"][ANDROID]["status"], "the other repo must still complete"
  end

  def test_reconcile_mode_partial_failure_rerun_converges
    existing_manifest
    mdir = File.join(@releases_dir, "releases", VERSION)
    # First attempt already got as far as pushing the ios branch + PR, but
    # the android push failed (simulated) and left the repo's ensure
    # incomplete — the manifest exists (status still whatever init left it
    # at) but android's branch was never pushed.
    @gh.stub_ls_remote("convos-ios", "refs/heads/hotfix/#{VERSION}", "ios-existing-branch-tip")
    @gh.stub_pr_list(repo: IOS, head: "hotfix/#{VERSION}", base: "main", state: "open",
                      result: [{ "number" => 5, "url" => "https://x/5", "merged_at" => nil }])

    result = new_hotfix.run(base_tag: BASE_TAG)

    assert_equal Dry::Monads::Success(:hotfixed), result

    # ios already had its branch + open PR — no duplicate mutations.
    ios_checkouts = @gh.calls_for(:checkout_branch).select { |c| c.args[0].end_with?("/convos-ios") }
    assert_empty ios_checkouts, "ios branch already existed — must not be recreated"
    ios_pr_creates = @gh.calls_for(:pr_create).select { |c| c.kwargs[:repo] == IOS }
    assert_empty ios_pr_creates, "ios PR already open — must not be recreated"

    # android converges: branch created, PR created.
    android_checkouts = @gh.calls_for(:checkout_branch).select { |c| c.args[0].end_with?("/convos-client") }
    assert_equal 1, android_checkouts.size
    android_pr_creates = @gh.calls_for(:pr_create).select { |c| c.kwargs[:repo] == ANDROID }
    assert_equal 1, android_pr_creates.size

    data = Train::Manifest.read(manifest_file)
    assert_equal "branched", data["repos"][ANDROID]["status"]
  end

  # ---- checkout sync guard ----

  def test_unsynced_releases_checkout_is_refused_before_any_mutation
    # Origin main moved past (or never got) the local HEAD — e.g. a prior
    # run committed the manifest locally but its push failed.
    @gh.stub_ls_remote(File.basename(@releases_dir), "refs/heads/main", "origin-tip")
    @gh.stub_rev_parse(File.basename(@releases_dir), "HEAD", "local-tip")

    result = new_hotfix.run(base_tag: BASE_TAG)

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/not at origin\/main \(local local-tip, origin origin-tip\)/, result.failure)
    refute @gh.called?(:clone), "an unsynced checkout must fail before touching any repo"

    # synced checkout proceeds normally
    @gh.stub_rev_parse(File.basename(@releases_dir), "HEAD", "origin-tip")
    assert_equal Dry::Monads::Success(:hotfixed), new_hotfix.run(base_tag: BASE_TAG)
  end

  # ---- extension: a hotfix reaching its second platform ----

  def test_single_platform_dispatch_extends_an_existing_hotfix_manifest
    existing_manifest(repos: { IOS => "ios-tag-sha" })
    mdir = File.join(@releases_dir, "releases", VERSION)
    File.write(File.join(mdir, "ios.md"), "already edited by a human\n")

    result = new_hotfix.run(base_tag: BASE_TAG, only_repo: ANDROID)

    assert_equal Dry::Monads::Success(:hotfixed), result

    data = Train::Manifest.read(manifest_file)
    assert_equal "android-tag-sha", data["repos"][ANDROID]["source-sha"]
    assert_equal "hotfix/#{VERSION}", data["repos"][ANDROID]["release-branch"]
    assert_equal "branched", data["repos"][ANDROID]["status"]
    assert_equal "ios-tag-sha", data["repos"][IOS]["source-sha"], "the existing repo's entry must be untouched"

    # only android participates: ios is never cloned or branched
    clone_urls = @gh.calls_for(:clone).map { |c| c.args[0] }
    refute(clone_urls.any? { |u| u.include?("convos-ios") })
    assert_equal 1, @gh.calls_for(:checkout_branch).size

    # the extension is committed to the manifest before any branch work
    commit_messages = @gh.calls_for(:commit).map { |c| c.args[1] }
    assert(commit_messages.any? { |m| m.include?("extend hotfix #{VERSION} to #{ANDROID}") })

    # android notes seeded; ios notes preserved verbatim
    assert_match(/#{Train::Notes::HOTFIX_PLACEHOLDER}/, File.read(File.join(mdir, "android.md")))
    assert_equal "already edited by a human\n", File.read(File.join(mdir, "ios.md"))
  end

  def test_extension_resets_a_promoted_top_level_status
    existing_manifest(repos: { IOS => "ios-tag-sha" })
    Train::Manifest.record_promotion(
      manifest_file, repo: IOS, key: "build-number", value: "100",
      tag: "v#{VERSION}", notes_sha: "n", run: "r"
    )
    assert_equal "promoted", Train::Manifest.read(manifest_file)["status"]

    result = new_hotfix.run(base_tag: BASE_TAG, only_repo: ANDROID)

    assert_equal Dry::Monads::Success(:hotfixed), result
    data = Train::Manifest.read(manifest_file)
    assert_equal "branched", data["status"], "an in-flight repo means the train is no longer promoted"
    assert_equal "promoted", data["repos"][IOS]["status"], "the shipped repo's state must survive"
    refute_nil data["repos"][IOS]["promoted"]
  end

  def test_both_platform_dispatch_converges_existing_and_extends_missing
    existing_manifest(repos: { IOS => "ios-tag-sha" })
    @gh.stub_ls_remote("convos-ios", "refs/heads/hotfix/#{VERSION}", "ios-branch-tip")
    @gh.stub_pr_list(repo: IOS, head: "hotfix/#{VERSION}", base: "main", state: "open",
                      result: [{ "number" => 5, "url" => "https://x/5", "merged_at" => nil }])

    result = new_hotfix.run(base_tag: BASE_TAG)

    assert_equal Dry::Monads::Success(:hotfixed), result
    data = Train::Manifest.read(manifest_file)
    assert_equal [ANDROID, IOS].sort, data["repos"].keys.sort

    ios_checkouts = @gh.calls_for(:checkout_branch).select { |c| c.args[0].end_with?("/convos-ios") }
    assert_empty ios_checkouts, "the existing repo converges — no recreation"
    android_checkouts = @gh.calls_for(:checkout_branch).select { |c| c.args[0].end_with?("/convos-client") }
    assert_equal 1, android_checkouts.size
  end

  def test_entry_with_missing_source_sha_is_a_mismatch_failure_not_a_crash
    existing_manifest(repos: { IOS => "ios-tag-sha" })
    data = Train::Manifest.read(manifest_file)
    data["repos"][IOS].delete("source-sha")
    Train::Manifest.write(manifest_file, data)

    result = new_hotfix.run(base_tag: BASE_TAG, only_repo: IOS)

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/source-sha mismatch/, result.failure)
  end

  def test_mismatched_existing_repo_blocks_extension
    existing_manifest(repos: { IOS => "stale-ios-sha" })

    result = new_hotfix.run(base_tag: BASE_TAG)

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/source-sha mismatch/, result.failure)
    data = Train::Manifest.read(manifest_file)
    refute data["repos"].key?(ANDROID), "a collision must not extend the manifest"
  end

  # ---- version arithmetic ----

  def test_version_arithmetic_v2_1_0_to_2_1_1
    result = new_hotfix.run(base_tag: "v2.1.0")
    assert_equal Dry::Monads::Success(:hotfixed), result
    assert File.exist?(manifest_file("2.1.1"))
  end

  def test_version_arithmetic_v2_1_5_to_2_1_6
    stub_repo_clones(latest_tag: "v2.1.5")
    @gh.stub_rev_parse("convos-ios", "v2.1.5^{commit}", "ios-tag-sha")
    @gh.stub_rev_parse("convos-client", "v2.1.5^{commit}", "android-tag-sha")

    result = new_hotfix.run(base_tag: "v2.1.5")

    assert_equal Dry::Monads::Success(:hotfixed), result
    assert File.exist?(manifest_file("2.1.6"))
  end

  # ---- dry-run ----

  def test_dry_run_makes_zero_mutations
    gh = FakeGithub.new(dry_run: true)
    gh.stub_clone("convos-ios") { |dest| write_ios_fixture(dest, "2.1.0") }
    gh.stub_clone("convos-client") { |dest| write_android_fixture(dest, "2.1.0") }
    gh.stub_latest_tag("convos-ios", BASE_TAG)
    gh.stub_latest_tag("convos-client", BASE_TAG)
    gh.stub_rev_parse("convos-ios", "#{BASE_TAG}^{commit}", "ios-tag-sha")
    gh.stub_rev_parse("convos-client", "#{BASE_TAG}^{commit}", "android-tag-sha")

    result = new_hotfix(gh).run(base_tag: BASE_TAG)

    assert_equal Dry::Monads::Success(:dry_run), result
    assert_match(/DRY RUN/, @out.string)
    refute Dir.exist?(File.join(@releases_dir, "releases", VERSION))
    %i[add commit push pr_create checkout_branch].each do |m|
      refute gh.called?(m), "dry-run must not call #{m}"
    end
  end
end
