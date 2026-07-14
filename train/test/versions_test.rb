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

  def test_bump_rejects_bad_format
    android_fixture(version: "2.1.0")
    assert_raises(Train::Versions::Error) { Train::Versions.bump(@dir, "2.2") }
    assert_raises(Train::Versions::Error) { Train::Versions.bump(@dir, "vNext") }
    assert_raises(Train::Versions::Error) { Train::Versions.bump(@dir, "2.2.0-rc1") }
  end

  def test_no_known_layout_fails
    empty = Dir.mktmpdir("train-versions-empty-")
    assert_raises(Train::Versions::Error) { Train::Versions.read(empty) }
  ensure
    FileUtils.remove_entry(empty) if empty
  end
end
