# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "train/github"

# The 2.6.0 promotion failure (2026-08-28) reproduced on real git, and the
# proof that cutting release/x.y.z as a MERGE of dev and main fixes it.
#
# These are not tests of a Train class — they pin the graph property
# Cut#build_release_tip depends on. Every other cut test runs against
# FakeGithub, which cannot merge anything; if git's three-way merge behaved
# differently from the argument written into Cut#ensure_release_branch, no
# other test here would notice, and the failure mode is a silently mis-stamped
# store artifact.
#
# The fixture is the graph from that morning:
#
#   A (2.5.0) ─── D1 (2.6.0: dev's post-cut bump) ─── D2 (dev keeps working)
#                    \
#                     M1 (2.5.0 restored on main for the 2.5.0 release)
#
# merge-base(main, D2) is D1, which ALREADY reads 2.6.0. So in a
# release-branch->main merge, main is the only side that changed the version
# line (2.6.0 -> 2.5.0) and the release branch is unchanged relative to the
# base. A three-way merge takes the side that changed: no conflict, no signal,
# and the merge commit comes out stamped 2.5.0 while the RC'd tip and the
# uploaded TestFlight build say 2.6.0.
class ReleaseBranchMergeTest < Minitest::Test
  VERSION_FILE = "version.txt"

  def setup
    @gh = Train::Github.new
    @dir = Dir.mktmpdir("train-release-merge-")
    git("init", "--quiet", "--initial-branch=mainline")
    git("config", "user.email", "base@example.com")
    git("config", "user.name", "Base")

    write_version("2.5.0")
    File.write(app_file, "v1\n")
    git("add", ".")
    git("commit", "--quiet", "-m", "A: shipped 2.5.0 content")

    # dev bumps to 2.6.0 right after the 2.5.0 cut; main absorbs dev up to
    # that bump (the back-merge) and then restores its own version.
    git("checkout", "--quiet", "-b", "dev")
    write_version("2.6.0")
    git("commit", "--quiet", "-am", "D1: bump dev to 2.6.0 after the 2.5.0 cut")

    git("checkout", "--quiet", "mainline")
    git("merge", "--quiet", "--no-ff", "-m", "back-merge dev", "dev")
    write_version("2.5.0")
    git("commit", "--quiet", "-am", "M1: restore MARKETING_VERSION for the 2.5.0 release")

    git("checkout", "--quiet", "dev")
    File.write(app_file, "v2\n")
    git("commit", "--quiet", "-am", "D2: work for 2.6.0")
  end

  def teardown
    FileUtils.remove_entry(@dir) if Dir.exist?(@dir)
  end

  # The precondition both cases share, and exactly what
  # Cut#warn_on_version_drift reports at cut time.
  def test_the_fixture_reproduces_the_arming_condition
    assert_equal "2.6.0", version_at(@gh.merge_base(@dir, "mainline", "dev"))
    assert_equal "2.5.0", version_at("mainline")
  end

  # What the old cut did: release/2.6.0 = dev's tip and nothing else.
  def test_cutting_at_devs_tip_alone_silently_stamps_the_release_with_mains_version
    git("branch", "release/2.6.0", "dev")

    assert_equal "2.6.0", version_at("release/2.6.0"), "the RC'd tip claims 2.6.0"

    merge_into_main("2.6.0")

    assert_equal "2.5.0", version_at("mainline"),
                 "reproduction failed: the incident IS that this merge silently yields 2.5.0"
    refute_equal tree_of("release/2.6.0"), tree_of("mainline"),
                 "and the merge tree differs from the RC'd tip — what Promote#assert_trees_match caught"
  end

  # What the cut does now. Because release/2.6.0 CONTAINS main's tip, the base
  # of the later release->main merge is main's own tip: main is unchanged, the
  # release branch is the only side that changed the version line, and the
  # merge can only resolve to the release's version.
  def test_cutting_as_a_merge_of_dev_and_main_keeps_the_release_version
    build_release_tip_the_way_the_cut_does("2.6.0")

    assert_equal "2.6.0", version_at("release/2.6.0")
    assert_equal @gh.rev_parse(@dir, "mainline"), @gh.merge_base(@dir, "mainline", "release/2.6.0"),
                 "the branch must contain main's tip — that is what resets the merge base"

    merge_into_main("2.6.0")

    assert_equal "2.6.0", version_at("mainline")
    assert_equal tree_of("release/2.6.0"), tree_of("mainline"),
                 "a branch containing main merges to exactly its own tree, so the merge commit " \
                 "and the RC'd tip can no longer disagree"
  end

  # Self-sustaining: shipping 2.6.0 leaves main correctly at 2.6.0 (no restore
  # commit to make), dev back-merges, and the next cut merges the new main in
  # again — so the property is re-established every week instead of decaying.
  def test_the_property_survives_the_following_week
    build_release_tip_the_way_the_cut_does("2.6.0")
    merge_into_main("2.6.0")

    git("checkout", "--quiet", "dev")
    git("merge", "--quiet", "--no-ff", "-m", "back-merge release/2.6.0", "release/2.6.0")
    write_version("2.7.0")
    git("commit", "--quiet", "-am", "bump dev to 2.7.0 after the 2.6.0 cut")
    File.write(app_file, "v3\n")
    git("commit", "--quiet", "-am", "work for 2.7.0")

    build_release_tip_the_way_the_cut_does("2.7.0")
    merge_into_main("2.7.0")

    assert_equal "2.7.0", version_at("mainline")
    assert_equal tree_of("release/2.7.0"), tree_of("mainline")
  end

  private

  # The Cut#build_release_tip recipe, driven through the same Github seams:
  # detach at dev's tip, merge main with --no-commit, re-assert the version,
  # commit once.
  def build_release_tip_the_way_the_cut_does(version)
    dev_sha = @gh.rev_parse(@dir, "dev")
    main_sha = @gh.rev_parse(@dir, "mainline")
    @gh.checkout(@dir, dev_sha)

    assert @gh.merge_no_commit(@dir, main_sha), "the fixture's merge must be clean"
    write_version(version)
    @gh.commit(@dir, "train: cut release/#{version} (merge main; version #{version})", all: true)

    git("branch", "-f", "release/#{version}", @gh.rev_parse(@dir))
  end

  # GitHub's "Create a merge commit": never a fast-forward, even when it could be.
  def merge_into_main(version)
    git("checkout", "--quiet", "mainline")
    git("merge", "--quiet", "--no-ff", "-m", "Merge release #{version}", "release/#{version}")
  end

  def app_file
    File.join(@dir, "app.txt")
  end

  def write_version(version)
    File.write(File.join(@dir, VERSION_FILE), "VERSION=#{version}\n")
  end

  def version_at(rev)
    @gh.show_file(@dir, rev, VERSION_FILE)[/VERSION=(\S+)/, 1]
  end

  def tree_of(rev)
    @gh.rev_parse(@dir, "#{rev}^{tree}")
  end

  def git(*args)
    system("git", "-C", @dir, *args, exception: true)
  end
end
