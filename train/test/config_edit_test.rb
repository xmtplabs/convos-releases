# frozen_string_literal: true

require_relative "test_helper"
require "minitest/autorun"
require "fileutils"
require "dry/monads"
require_relative "../lib/train/config_edit"
require_relative "support/fake_github"

class ConfigEditTest < Minitest::Test
  REAL = <<~YAML
    # Release train schedule. The cron slots in release-cut.yml are the time
    # authority (15:45 America/New_York); this file controls day + skips.
    cut-day: thursday
    skip-dates: []           # ISO dates, e.g. [2026-11-26]
  YAML

  def test_adds_a_date_preserving_comments_and_trailer
    result = Train::ConfigEdit.add_to_text(REAL, "2026-11-26")
    assert result.success?
    state, text = result.value!
    assert_equal :changed, state
    assert_includes text, "# Release train schedule."
    assert_includes text, 'skip-dates: ["2026-11-26"]           # ISO dates, e.g. [2026-11-26]'
    assert_includes text, "cut-day: thursday"
  end

  def test_inserts_sorted_and_is_idempotent
    once = Train::ConfigEdit.add_to_text(REAL, "2026-12-24").value![1]
    twice = Train::ConfigEdit.add_to_text(once, "2026-11-26").value![1]
    assert_includes twice, 'skip-dates: ["2026-11-26", "2026-12-24"]'
    state, text = Train::ConfigEdit.add_to_text(twice, "2026-11-26").value!
    assert_equal :unchanged, state
    assert_equal twice, text
  end

  def test_fails_loudly_on_block_style_skip_dates
    block = "cut-day: thursday\nskip-dates:\n  - 2026-11-26\n"
    result = Train::ConfigEdit.add_to_text(block, "2026-12-24")
    assert result.failure?
    assert_match(/not the expected inline array/, result.failure)
  end

  def test_fails_loudly_on_multiple_skip_dates_lines
    dup = "cut-day: thursday\nskip-dates: []\nskip-dates: []\n"
    result = Train::ConfigEdit.add_to_text(dup, "2026-12-24")
    assert result.failure?
    assert_match(/multiple skip-dates/, result.failure)
  end

  def test_fails_loudly_on_inline_and_block_style_skip_dates_pair
    dup = "cut-day: thursday\nskip-dates: []\nskip-dates:\n  - 2026-11-26\n"
    result = Train::ConfigEdit.add_to_text(dup, "2026-12-24")
    assert result.failure?
    assert_match(/multiple skip-dates/, result.failure)
  end

  FakeGh = Struct.new(:dry_run)

  def test_add_skip_date_rejects_bad_format_and_past_dates
    edit = Train::ConfigEdit.new(github: FakeGh.new(false), out: StringIO.new)
    assert_match(/not an ISO date/, edit.add_skip_date(date: "26-11-2026").failure)
    assert_match(/not an ISO date/, edit.add_skip_date(date: "garbage").failure)
    assert_match(/in the past/, edit.add_skip_date(date: "2000-01-01").failure)
  end

  def test_dry_run_writes_nothing
    out = StringIO.new
    edit = Train::ConfigEdit.new(github: FakeGh.new(true), out: out)
    result = edit.add_skip_date(date: "2999-12-31")
    assert result.success?
    assert_match(/dry-run/, out.string)
  end

  # ---- write path: ConfigEdit -> StateWriter closure wiring, real fake-github-backed clone ----

  def setup
    @out = StringIO.new
    @gh = FakeGithub.new
    @gh.stub_clone("convos-releases") { |dest| File.write(File.join(dest, "release-config.yml"), REAL) }
  end

  def new_edit(gh = @gh)
    Train::ConfigEdit.new(github: gh, out: @out)
  end

  def test_add_skip_date_success_clones_rewrites_commits_and_pushes
    # commit() runs before StateWriter tears the clone dir down in its ensure
    # block, so it's the last moment the rewritten file is readable on disk.
    written = nil
    gh = FakeGithub.new
    gh.stub_clone("convos-releases") { |dest| File.write(File.join(dest, "release-config.yml"), REAL) }
    gh.define_singleton_method(:commit) do |dir, message, all: false|
      written = File.read(File.join(dir, "release-config.yml"))
      record(:commit, [dir, message], { all: all })
      true
    end

    result = new_edit(gh).add_skip_date(date: "2999-12-31", requested_by: "testuser")

    assert_equal Dry::Monads::Success(true), result
    assert_equal 1, gh.calls_for(:clone).size

    commits = gh.calls_for(:commit)
    assert_equal 1, commits.size
    assert_equal "train: skip 2999-12-31 (via testuser)", commits.first.args[1]

    assert_equal 1, gh.calls_for(:push).size

    assert_includes written, '"2999-12-31"'
  end

  def test_add_skip_date_already_present_is_success_without_a_commit
    # Simulate the real Github#commit's no-change-ok semantics (git says
    # "nothing to commit" -> false): the date's already in the clone's file,
    # so add_to_text returns :unchanged and nothing gets written.
    gh = FakeGithub.new
    gh.stub_clone("convos-releases") do |dest|
      seeded = Train::ConfigEdit.add_to_text(REAL, "2999-12-31").value![1]
      File.write(File.join(dest, "release-config.yml"), seeded)
    end
    def gh.commit(dir, message, all: false)
      record(:commit, [dir, "no-change"], { all: all })
      false # nothing to commit
    end

    result = new_edit(gh).add_skip_date(date: "2999-12-31", requested_by: "testuser")

    assert_equal Dry::Monads::Success(true), result
    refute gh.called?(:push), "no-change commit must not attempt a push"
  end

  def test_add_skip_date_fails_on_block_style_clone_without_a_push
    gh = FakeGithub.new
    block = "cut-day: thursday\nskip-dates:\n  - 2026-11-26\n"
    gh.stub_clone("convos-releases") { |dest| File.write(File.join(dest, "release-config.yml"), block) }

    result = new_edit(gh).add_skip_date(date: "2999-12-31", requested_by: "testuser")

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/not the expected inline array/, result.failure)
    refute gh.called?(:push), "a rejected clone shape must not be pushed"
  end
end
