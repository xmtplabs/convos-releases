# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "retriable"
require "dry/monads"
require "train/state_writer"
require_relative "support/fake_github"

class StateWriterTest < Minitest::Test
  include Dry::Monads[:result]

  def setup
    @out = StringIO.new
    @gh = FakeGithub.new
    @gh.stub_clone("convos-releases") { |dest| FileUtils.mkdir_p(dest) }
  end

  def new_writer(gh = @gh)
    Train::StateWriter.new(github: gh, out: @out)
  end

  # retriable's default backoff sleeps between attempts; every retry test
  # runs under sleep_disabled so the suite doesn't pay real wall-clock time
  # for a scripted failure.
  def without_sleep
    Retriable.with_override(sleep_disabled: true) { yield }
  end

  # ---- happy write ----

  def test_happy_write_clones_mutates_commits_and_pushes
    marker_existed_during_block = false
    result = new_writer.write(message: "train: test write") do |dir|
      File.write(File.join(dir, "marker.txt"), "hello")
      marker_existed_during_block = File.exist?(File.join(dir, "marker.txt"))
      Success(true)
    end

    assert_equal Dry::Monads::Success(true), result
    assert marker_existed_during_block, "block must be able to write into the cloned dir"
    assert_equal 1, @gh.calls_for(:clone).size
    assert_equal 1, @gh.calls_for(:git_config_bot).size
    assert_equal 1, @gh.calls_for(:commit).size
    assert_equal "train: test write", @gh.calls_for(:commit).first.args[1]
    assert_equal 1, @gh.calls_for(:push).size
    assert_equal "HEAD:main", @gh.calls_for(:push).first.args[1]
  end

  def test_block_receives_a_directory_that_no_longer_exists_after_write
    dir_used = nil
    new_writer.write(message: "m") do |dir|
      dir_used = dir
      Success(true)
    end

    refute Dir.exist?(dir_used), "tmpdir must be cleaned up after write"
  end

  # ---- push contention retry ----

  def test_push_contention_retries_with_a_fresh_clone_each_attempt
    @gh.fail_push_times("HEAD:main", 2) # fails twice, succeeds on the 3rd attempt

    result = without_sleep do
      new_writer.write(message: "m") { |_dir| Success(true) }
    end

    assert_equal Dry::Monads::Success(true), result
    assert_equal 3, @gh.calls_for(:clone).size, "each retry must start from a fresh clone"
    assert_equal 3, @gh.calls_for(:push).size
  end

  def test_push_contention_exhausts_after_three_attempts_with_loud_failure
    @gh.fail_push_times("HEAD:main", 99) # never succeeds

    result = without_sleep do
      new_writer.write(message: "m") { |_dir| Success(true) }
    end

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/push contention/i, result.failure)
    assert_equal 3, @gh.calls_for(:clone).size
    assert_equal 3, @gh.calls_for(:push).size
  end

  # ---- no-change commit is success, no push ----

  def test_no_change_commit_is_success_without_a_push
    gh = FakeGithub.new
    gh.stub_clone("convos-releases") { |dest| FileUtils.mkdir_p(dest) }
    def gh.commit(dir, _message, all: false)
      record(:commit, [dir, "no-change"], { all: all })
      false # nothing to commit
    end

    result = new_writer(gh).write(message: "m") { |_dir| Success(true) }

    assert_equal Dry::Monads::Success(true), result
    refute gh.called?(:push), "no-change commit must not attempt a push"
  end

  # ---- block-level hard failure short-circuits without commit/push ----

  def test_block_failure_short_circuits_before_commit_and_push
    result = new_writer.write(message: "m") { |_dir| Failure("no manifest for 9.9.9") }

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/no manifest for 9\.9\.9/, result.failure)
    refute @gh.called?(:git_config_bot)
    refute @gh.called?(:commit)
    refute @gh.called?(:push)
  end

  # ---- non-push CommandErrors propagate unchanged, not retried ----

  def test_clone_command_error_propagates_unchanged_without_retry
    @gh.fail_clone_times("convos-releases", 99)

    assert_raises(Train::Github::CommandError) do
      without_sleep { new_writer.write(message: "m") { |_dir| Success(true) } }
    end
    assert_equal 1, @gh.calls_for(:clone).size, "clone must not be retried for a non-push CommandError"
  end
end
