# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "train/versions"

class VersionsTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("train-versions-test-")
  end

  def teardown
    FileUtils.remove_entry(@dir)
    FileUtils.remove_entry(@other_dir) if @other_dir
  end

  def android_fixture(version: "2.1.0")
    FileUtils.mkdir_p(File.join(@dir, "android"))
    path = File.join(@dir, "android", "gradle.properties")
    File.write(path, <<~PROPS)
      # generated
      VERSION_CODE=29735012
      VERSION_NAME=#{version}
      org.gradle.jvmargs=-Xmx4g
    PROPS
    path
  end

  def ios_fixture(versions: %w[2.1.0 2.1.0 2.1.0])
    FileUtils.mkdir_p(File.join(@dir, "Convos.xcodeproj"))
    path = File.join(@dir, "Convos.xcodeproj", "project.pbxproj")
    entries = versions.map do |v|
      <<~ENTRY
        		A1B2C3D4 /* Debug */ = {
        			isa = XCBuildConfiguration;
        			buildSettings = {
        				MARKETING_VERSION = #{v};
        				PRODUCT_NAME = Convos;
        			};
        		};
      ENTRY
    end.join("\n")
    File.write(path, entries)
    path
  end

  def test_read_android
    android_fixture(version: "2.1.0")
    assert_equal "2.1.0", Train::Versions.read(@dir)
  end

  def test_read_ios_agreeing_entries
    ios_fixture(versions: %w[2.1.0 2.1.0 2.1.0])
    assert_equal "2.1.0", Train::Versions.read(@dir)
  end

  def test_read_ios_inconsistent_entries_fails
    ios_fixture(versions: %w[2.1.0 2.1.0 2.2.0])
    assert_raises(Train::Versions::Error) { Train::Versions.read(@dir) }
  end

  def test_read_rejects_bad_version_format
    android_fixture(version: "foo")
    error = assert_raises(Train::Versions::Error) { Train::Versions.read(@dir) }
    assert_match(/bad version 'foo'/, error.message)
  end

  def test_bump_android
    android_fixture(version: "2.1.0")
    Train::Versions.bump(@dir, "2.2.0")
    assert_equal "2.2.0", Train::Versions.read(@dir)
    # VERSION_CODE must be untouched — epoch lane owns Play codes.
    content = File.read(File.join(@dir, "android", "gradle.properties"))
    assert_match(/VERSION_CODE=29735012/, content)
  end

  def test_bump_ios_updates_all_entries
    ios_fixture(versions: %w[2.1.0 2.1.0 2.1.0])
    Train::Versions.bump(@dir, "2.2.0")
    assert_equal "2.2.0", Train::Versions.read(@dir)
    content = File.read(File.join(@dir, "Convos.xcodeproj", "project.pbxproj"))
    assert_equal 3, content.scan("MARKETING_VERSION = 2.2.0;").size
  end

  # bump rewrites app-owned files (the pbxproj especially is dense generated
  # state), so it must PROVE the only lines it changed are version lines —
  # the version pattern embedded inside some other setting's value must
  # abort the write, never silently rewrite it.
  def test_bump_ios_refuses_to_touch_a_non_version_line
    path = ios_fixture(versions: %w[2.1.0 2.1.0])
    File.write(path, File.read(path) + "\t\t\t\tOTHER_SETTING = \"MARKETING_VERSION = 2.1.0;\";\n")

    error = assert_raises(Train::Versions::Error) { Train::Versions.bump(@dir, "2.2.0") }
    assert_match(/non-version line/, error.message)
    # No partial write: the file must be byte-identical to before the bump.
    content = File.read(path)
    assert_includes content, "OTHER_SETTING = \"MARKETING_VERSION = 2.1.0;\";"
    assert_equal 0, content.scan("MARKETING_VERSION = 2.2.0;").size
  end

  def test_bump_rejects_bad_format
    android_fixture(version: "2.1.0")
    assert_raises(Train::Versions::Error) { Train::Versions.bump(@dir, "2.2") }
    assert_raises(Train::Versions::Error) { Train::Versions.bump(@dir, "vNext") }
    assert_raises(Train::Versions::Error) { Train::Versions.bump(@dir, "2.2.0-rc1") }
  end

  # ---- check_aligned: intra-repo (read) + cross-repo agreement ----

  def other_dir
    @other_dir ||= Dir.mktmpdir("train-versions-other-")
  end

  def android_fixture_in(dir, version:)
    FileUtils.mkdir_p(File.join(dir, "android"))
    File.write(File.join(dir, "android", "gradle.properties"), "VERSION_NAME=#{version}\n")
  end

  # ---- from_ref (what a train branch name claims) ----

  def test_from_ref_reads_release_and_hotfix_branches
    assert_equal "2.6.0", Train::Versions.from_ref("release/2.6.0")
    assert_equal "2.6.1", Train::Versions.from_ref("hotfix/2.6.1")
  end

  def test_from_ref_is_nil_for_anything_that_is_not_a_train_branch
    # The guard must stay silent on these, not fail the build.
    [
      "dev", "main", "feature/release/2.6.0", "release", "releases/2.6.0",
      "release/", "release/2.6", "release/v2.6.0", "release/2.6.0-rc1",
      "hotfix/2.06.0", "", nil
    ].each do |ref|
      assert_nil Train::Versions.from_ref(ref), "expected #{ref.inspect} to be rejected"
    end
  end

  def test_check_aligned_passes_when_all_agree
    android_fixture(version: "2.1.0")
    android_fixture_in(other_dir, version: "2.1.0")
    assert_equal "2.1.0",
      Train::Versions.check_aligned("client" => @dir, "ios" => other_dir)
  end

  def test_check_aligned_fails_on_cross_repo_mismatch
    android_fixture(version: "2.1.0")
    android_fixture_in(other_dir, version: "2.2.0")
    error = assert_raises(Train::Versions::Error) do
      Train::Versions.check_aligned("client" => @dir, "ios" => other_dir)
    end
    assert_match(/app versions disagree/, error.message)
    assert_match(/client: 2\.1\.0/, error.message)
    assert_match(/ios: 2\.2\.0/, error.message)
  end

  def test_check_aligned_surfaces_intra_repo_split
    # The ShareExtension-stuck-at-2.0.0 incident: one repo internally split.
    ios_fixture(versions: %w[2.2.0 2.2.0 2.0.0])
    android_fixture_in(other_dir, version: "2.2.0")
    error = assert_raises(Train::Versions::Error) do
      Train::Versions.check_aligned("ios" => @dir, "client" => other_dir)
    end
    assert_match(/inconsistent versions found/, error.message)
  end

  def test_check_aligned_rejects_empty
    assert_raises(Train::Versions::Error) { Train::Versions.check_aligned({}) }
  end

  def test_no_known_layout_fails
    empty = Dir.mktmpdir("train-versions-empty-")
    assert_raises(Train::Versions::Error) { Train::Versions.read(empty) }
  ensure
    FileUtils.remove_entry(empty) if empty
  end

  # ---- version arithmetic (semantic gem behind the strict X.Y.Z gate) ----

  def test_next_minor_resets_patch
    assert_equal "2.2.0", Train::Versions.next_minor("2.1.3")
  end

  def test_next_patch
    assert_equal "2.1.1", Train::Versions.next_patch("2.1.0")
  end

  def test_arithmetic_stays_strict_where_semver_is_lax
    # Semantic::Version would happily parse these; train versions must not.
    assert_raises(Train::Versions::Error) { Train::Versions.next_minor("2.1") }
    assert_raises(Train::Versions::Error) { Train::Versions.next_minor("2.1.0-rc.1") }
    assert_raises(Train::Versions::Error) { Train::Versions.next_patch("2.1.0+build5") }
  end

  def test_leading_zeros_are_invalid_and_never_leak_argument_error
    refute Train::Versions.valid?("02.1.0")
    # Versions::Error, not the semantic gem's raw ArgumentError.
    assert_raises(Train::Versions::Error) { Train::Versions.next_minor("02.1.0") }
    # plain zero components stay fine
    assert_equal "0.2.0", Train::Versions.next_minor("0.1.3")
  end

  def test_tag_round_trip
    assert_equal "v2.1.0", Train::Versions.tag("2.1.0")
    assert_equal "2.1.0", Train::Versions.from_tag("v2.1.0")
  end

  def test_from_tag_rejects_everything_else
    assert_nil Train::Versions.from_tag("2.1.0")
    assert_nil Train::Versions.from_tag("v2.1")
    assert_nil Train::Versions.from_tag("v2.1.0.5")
    assert_nil Train::Versions.from_tag("v2.1.0-rc.1")
  end
end
