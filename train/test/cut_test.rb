# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "dry/monads"
require "train/cut"
require_relative "support/fake_github"

class CutTest < Minitest::Test
  EDT_THU = "2026-07-16" # forces the slot decision to "go" without needing --force

  def setup
    @releases_dir = Dir.mktmpdir("train-cut-test-")
    File.write(File.join(@releases_dir, "release-config.yml"), "cut-day: thursday\nskip-dates: []\n")
    FileUtils.mkdir_p(File.join(@releases_dir, "releases"))
    @gh = FakeGithub.new
    stub_repo_clones(version: "2.1.0")
    @out = StringIO.new
    @err = StringIO.new
  end

  def teardown
    FileUtils.remove_entry(@releases_dir)
  end

  def stub_repo_clones(version:, ios_version: nil, client_version: nil)
    ios_version ||= version
    client_version ||= version
    @gh.stub_clone("convos-ios") do |dest|
      FileUtils.mkdir_p(File.join(dest, "android")) # no-op, keeps symmetry
      write_ios_fixture(dest, ios_version)
    end
    @gh.stub_clone("convos-client") do |dest|
      write_android_fixture(dest, client_version)
    end
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

  def new_cut(gh = @gh)
    Train::Cut.new(github: gh, releases_dir: @releases_dir, out: @out, err: @err)
  end

  def test_dry_run_produces_plan_and_zero_mutations
    gh = FakeGithub.new(dry_run: true)
    stub_clones_on(gh, version: "2.1.0")
    cut = Train::Cut.new(github: gh, releases_dir: @releases_dir, out: @out, err: @err)

    result = cut.run(force: true, date_override: EDT_THU)

    assert_equal Dry::Monads::Success(:dry_run), result
    assert_match(/DRY RUN/, @out.string)
    assert_match(/2\.2\.0/, @out.string) # next dev version printed in the plan

    # zero filesystem mutations: no releases/2.1.0 dir created
    refute Dir.exist?(File.join(@releases_dir, "releases", "2.1.0"))
    # zero git mutations: no add/commit/push/pr_create/pr_merge_auto calls
    %i[add commit push pr_create pr_merge_auto].each do |m|
      refute gh.called?(m), "dry-run must not call #{m}"
    end
  end

  def stub_clones_on(gh, version:)
    gh.stub_clone("convos-ios") { |dest| write_ios_fixture(dest, version) }
    gh.stub_clone("convos-client") { |dest| write_android_fixture(dest, version) }
  end

  def test_version_disagreement_aborts_before_any_mutation
    gh = FakeGithub.new
    gh.stub_clone("convos-ios") { |dest| write_ios_fixture(dest, "2.1.0") }
    gh.stub_clone("convos-client") { |dest| write_android_fixture(dest, "2.2.0") }
    cut = Train::Cut.new(github: gh, releases_dir: @releases_dir, out: @out, err: @err)

    result = cut.run(force: true, date_override: EDT_THU)

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/disagree on version/i, result.failure)
    refute Dir.exist?(File.join(@releases_dir, "releases", "2.1.0"))
    refute Dir.exist?(File.join(@releases_dir, "releases", "2.2.0"))
    %i[add commit push pr_create].each { |m| refute gh.called?(m) }
  end

  def test_declines_cleanly_when_not_cut_time
    cut = new_cut
    # Friday, not Thursday — and no --force.
    result = cut.run(force: false, schedule: "45 19 * * *", date_override: "2026-07-17")

    assert_equal Dry::Monads::Success(:skipped), result
    assert_match(/not thursday/i, @out.string)
    assert_empty Dir.children(File.join(@releases_dir, "releases")), "declining before slot check must not touch releases/"
  end

  def test_full_cut_creates_manifest_and_notes_and_prs
    @gh.stub_pr_list(repo: "xmtplabs/convos-ios", head: "bot/bump-2.2.0", base: nil, state: "all", result: [])
    @gh.stub_pr_list(repo: "xmtplabs/convos-client", head: "bot/bump-2.2.0", base: nil, state: "all", result: [])
    @gh.stub_pr_list(repo: "xmtplabs/convos-ios", head: "release/2.1.0", base: "main", state: "open", result: [])
    @gh.stub_pr_list(repo: "xmtplabs/convos-client", head: "release/2.1.0", base: "main", state: "open", result: [])
    @gh.set_dirty(true)

    cut = new_cut
    result = cut.run(force: true, date_override: EDT_THU)
    assert_equal Dry::Monads::Success(:cut), result

    mfile = File.join(@releases_dir, "releases", "2.1.0", "manifest.yml")
    assert File.exist?(mfile), "manifest.yml should be committed"
    assert File.exist?(File.join(@releases_dir, "releases", "2.1.0", "ios.md"))
    assert File.exist?(File.join(@releases_dir, "releases", "2.1.0", "android.md"))
    assert File.exist?(File.join(@releases_dir, "releases", "2.1.0", "submission-notes.md"))

    data = Train::Manifest.read(mfile)
    assert_equal "2.1.0", data["version"]
    assert_equal "release", data["kind"]
    assert_equal "branched", data["repos"]["xmtplabs/convos-ios"]["status"]
    assert_equal "branched", data["repos"]["xmtplabs/convos-client"]["status"]

    assert @gh.called?(:pr_create)
    pr_titles = @gh.calls_for(:pr_create).map { |c| c.kwargs[:title] }
    assert_includes pr_titles, "Bump version to 2.2.0"
    assert_includes pr_titles, "Release 2.1.0"
  end

  def test_in_flight_manifest_same_day_reconciles_instead_of_recutting
    # Simulate an interrupted cut: manifest already exists for today with
    # status:cut (never advanced past cut).
    mdir = File.join(@releases_dir, "releases", "2.1.0")
    FileUtils.mkdir_p(mdir)
    Train::Manifest.init(
      File.join(mdir, "manifest.yml"), version: "2.1.0", kind: "release", cut_date: EDT_THU,
      repos: { "xmtplabs/convos-ios" => "preexisting-ios-sha", "xmtplabs/convos-client" => "preexisting-client-sha" }
    )
    File.write(File.join(mdir, "ios.md"), "old notes")
    File.write(File.join(mdir, "android.md"), "old notes")

    @gh.stub_pr_list(repo: "xmtplabs/convos-ios", head: "bot/bump-2.2.0", base: nil, state: "all", result: [])
    @gh.stub_pr_list(repo: "xmtplabs/convos-client", head: "bot/bump-2.2.0", base: nil, state: "all", result: [])
    @gh.stub_pr_list(repo: "xmtplabs/convos-ios", head: "release/2.1.0", base: "main", state: "open", result: [])
    @gh.stub_pr_list(repo: "xmtplabs/convos-client", head: "release/2.1.0", base: "main", state: "open", result: [])
    @gh.set_dirty(true)

    # Capture phase will see dev at "2.1.0" again (stubbed clones); the
    # in-flight scan must pick up the EXISTING manifest's recorded SHAs
    # rather than the freshly-captured ones, and must NOT re-run
    # Manifest.init (would raise on existing file).
    cut = new_cut
    result = cut.run(force: true, date_override: EDT_THU)
    assert_equal Dry::Monads::Success(:cut), result
    assert_match(/reconciling/i, @out.string)

    # Notes files were not clobbered by re-running init (init would have
    # raised before that anyway — this asserts the reconcile path was
    # actually taken).
    assert_equal "old notes", File.read(File.join(mdir, "ios.md"))

    data = Train::Manifest.read(File.join(mdir, "manifest.yml"))
    assert_equal "preexisting-ios-sha", data["repos"]["xmtplabs/convos-ios"]["source-sha"]
    assert_equal "branched", data["repos"]["xmtplabs/convos-ios"]["status"]
  end

  def test_stale_in_flight_manifest_from_earlier_date_aborts
    mdir = File.join(@releases_dir, "releases", "2.0.0")
    FileUtils.mkdir_p(mdir)
    Train::Manifest.init(
      File.join(mdir, "manifest.yml"), version: "2.0.0", kind: "release", cut_date: "2026-07-09",
      repos: { "xmtplabs/convos-ios" => "old-sha", "xmtplabs/convos-client" => "old-sha" }
    )

    cut = new_cut
    result = cut.run(force: true, date_override: EDT_THU)

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/still status:cut/i, result.failure)
    refute Dir.exist?(File.join(@releases_dir, "releases", "2.1.0"))
  end

  def test_release_branch_mismatch_fails_loud
    @gh.stub_ls_remote("convos-ios", "refs/heads/release/2.1.0", "some-other-sha")
    @gh.stub_pr_list(repo: "xmtplabs/convos-ios", head: "bot/bump-2.2.0", base: nil, state: "all", result: [])
    @gh.stub_pr_list(repo: "xmtplabs/convos-client", head: "bot/bump-2.2.0", base: nil, state: "all", result: [])
    @gh.stub_pr_list(repo: "xmtplabs/convos-ios", head: "release/2.1.0", base: "main", state: "open", result: [])
    @gh.stub_pr_list(repo: "xmtplabs/convos-client", head: "release/2.1.0", base: "main", state: "open", result: [])

    cut = new_cut
    result = cut.run(force: true, date_override: EDT_THU)

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/exists at .* expected/i, result.failure)
  end

  def test_release_branch_mismatch_on_one_repo_still_reports_the_others_outcome
    # convos-ios has a mismatched release branch; convos-client has no such
    # problem. Both ensures must run — convos-client's branch/PRs get
    # created and its manifest status advances to "branched" — even though
    # the overall Result is a Failure naming convos-ios.
    @gh.stub_ls_remote("convos-ios", "refs/heads/release/2.1.0", "some-other-sha")
    @gh.stub_pr_list(repo: "xmtplabs/convos-ios", head: "bot/bump-2.2.0", base: nil, state: "all", result: [])
    @gh.stub_pr_list(repo: "xmtplabs/convos-client", head: "bot/bump-2.2.0", base: nil, state: "all", result: [])
    @gh.stub_pr_list(repo: "xmtplabs/convos-ios", head: "release/2.1.0", base: "main", state: "open", result: [])
    @gh.stub_pr_list(repo: "xmtplabs/convos-client", head: "release/2.1.0", base: "main", state: "open", result: [])

    cut = new_cut
    result = cut.run(force: true, date_override: EDT_THU)

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/xmtplabs\/convos-ios/, result.failure)

    mfile = File.join(@releases_dir, "releases", "2.1.0", "manifest.yml")
    data = Train::Manifest.read(mfile)
    assert_equal "pending", data["repos"]["xmtplabs/convos-ios"]["status"]
    assert_equal "branched", data["repos"]["xmtplabs/convos-client"]["status"]
    assert @gh.calls_for(:pr_create).any? { |c| c.kwargs[:repo] == "xmtplabs/convos-client" }
  end
end
