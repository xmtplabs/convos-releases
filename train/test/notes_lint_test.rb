# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"
require "train/notes_lint"

class NotesLintTest < Minitest::Test
  def with_dir(files, kind: "hotfix")
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "manifest.yml"), "kind: #{kind}\n")
      files.each { |name, content| File.write(File.join(dir, name), content) }
      yield dir
    end
  end

  def test_clean_notes_pass_and_report_rendered_lengths
    files = {
      "ios.md" => "## Features\n- Nice thing\n",
      "android.md" => "## Fixes\n- Small fix\n",
      "submission-notes.md" => "See [test plan](https://example.com/plan).\n"
    }
    with_dir(files, kind: "release") do |dir|
      report = Train::NotesLint.check(dir)

      assert_empty report[:errors]
      assert_equal 3, report[:checked].length
      assert report[:checked].all? { |line| line.include?("chars rendered") }
    end
  end

  def test_android_over_play_limit_is_an_error
    with_dir({ "android.md" => "- #{"x" * 600}\n" }) do |dir|
      report = Train::NotesLint.check(dir)

      assert_equal 1, report[:errors].length
      assert_match(/Play limit 500/, report[:errors].first)
    end
  end

  def test_seeded_hotfix_placeholder_is_an_error
    with_dir({ "ios.md" => "- #{Train::Notes::HOTFIX_PLACEHOLDER}\n" }) do |dir|
      report = Train::NotesLint.check(dir)

      assert_match(/placeholder/, report[:errors].first)
    end
  end

  def test_notes_rendering_to_empty_store_text_is_an_error
    with_dir({ "ios.md" => "<!-- only a comment -->\n" }) do |dir|
      report = Train::NotesLint.check(dir)

      assert_match(/renders to empty/, report[:errors].first)
    end
  end

  def test_missing_files_are_skipped_not_errors_for_hotfix
    with_dir({ "ios.md" => "- Just iOS this time\n" }) do |dir|
      report = Train::NotesLint.check(dir)

      assert_empty report[:errors]
      assert_equal 1, report[:checked].length
    end
  end

  def test_no_manifest_is_an_error
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "ios.md"), "- Something\n")
      report = Train::NotesLint.check(dir)

      assert_match(/no manifest\.yml/, report[:errors].first)
    end
  end

  def test_release_kind_missing_android_is_an_error_naming_the_file
    files = {
      "ios.md" => "## Features\n- Nice thing\n",
      "submission-notes.md" => "See [test plan](https://example.com/plan).\n"
    }
    with_dir(files, kind: "release") do |dir|
      report = Train::NotesLint.check(dir)

      assert_match(/android\.md/, report[:errors].join("; "))
    end
  end

  def test_hotfix_kind_single_file_is_ok
    with_dir({ "ios.md" => "- Just iOS this time\n" }, kind: "hotfix") do |dir|
      report = Train::NotesLint.check(dir)

      assert_empty report[:errors]
    end
  end

  def test_seeded_reviewer_placeholder_is_an_error
    with_dir({ "submission-notes.md" => "#{Train::Notes::REVIEWER_PLACEHOLDER}\n" }) do |dir|
      report = Train::NotesLint.check(dir)

      assert_match(/placeholder/, report[:errors].first)
    end
  end

  def test_wrong_case_kind_is_an_error
    with_dir({ "ios.md" => "- Just iOS this time\n" }, kind: "Release") do |dir|
      report = Train::NotesLint.check(dir)

      assert_match(/kind "Release" is not release or hotfix/, report[:errors].join("; "))
    end
  end

  def test_absent_kind_is_an_error
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "manifest.yml"), "version: 1.0.0\n")
      File.write(File.join(dir, "ios.md"), "- Just iOS this time\n")
      report = Train::NotesLint.check(dir)

      assert_match(/kind nil is not release or hotfix/, report[:errors].join("; "))
    end
  end
end
