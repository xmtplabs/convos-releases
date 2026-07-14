# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "retriable"
require "dry/monads"
require "train/append"
require "train/manifest"
require_relative "support/fake_github"

class AppendTest < Minitest::Test
  def setup
    @out = StringIO.new
    @gh = FakeGithub.new
    @gh.stub_clone("convos-releases") { |dest| write_manifest_fixture(dest, "2.1.0") }
  end

  def write_manifest_fixture(dest, version)
    mdir = File.join(dest, "releases", version)
    FileUtils.mkdir_p(mdir)
    Train::Manifest.init(
      File.join(mdir, "manifest.yml"), version: version, kind: "release", cut_date: "2026-07-16",
      repos: { "xmtplabs/convos-ios" => "sha-ios" }
    )
  end

  def new_append(gh = @gh)
    Train::Append.new(github: gh, out: @out)
  end

  # retriable's default backoff sleeps between attempts; every retry test
  # runs under sleep_disabled so the suite doesn't pay real wall-clock time
  # for a scripted failure.
  def without_sleep
    Retriable.with_override(sleep_disabled: true) { yield }
  end

  def base_args
    { repo: "xmtplabs/convos-ios", sha: "abc123", run_url: "https://run/1", key: "build-number", value: "421" }
  end

  def test_rejects_non_integer_value
    result = new_append.run(**base_args, value: "abc")

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/positive integer/, result.failure)
    refute @gh.called?(:clone)
  end

  def test_rejects_zero_and_leading_zeros
    ["0", "000"].each do |bad|
      result = new_append.run(**base_args, value: bad)

      assert_instance_of Dry::Monads::Result::Failure, result
      assert_match(/positive integer/, result.failure)
      refute @gh.called?(:clone)
    end
  end

  def test_requires_a_derivable_version
    ENV.delete("GITHUB_REF_NAME")
    result = new_append.run(**base_args, version: nil)

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/cannot derive version/, result.failure)
    refute @gh.called?(:clone)
  end

  def test_dry_run_short_circuits_before_any_clone
    gh = FakeGithub.new(dry_run: true)
    result = new_append(gh).run(**base_args, version: "2.1.0")

    assert_equal Dry::Monads::Success(true), result
    assert_match(/\[dry-run\] would append rc/, @out.string)
    refute gh.called?(:clone)
  end

  def test_success_clones_appends_commits_and_pushes
    result = new_append.run(**base_args, version: "2.1.0")

    assert_equal Dry::Monads::Success(true), result
    assert_equal 1, @gh.calls_for(:clone).size
    assert_equal 1, @gh.calls_for(:commit).size
    assert_equal 1, @gh.calls_for(:push).size
  end

  def test_no_manifest_for_version_is_a_hard_failure_not_retried
    result = new_append.run(**base_args, version: "9.9.9")

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/no manifest for 9\.9\.9/, result.failure)
    assert_equal 1, @gh.calls_for(:clone).size, "a missing manifest must not be retried as push contention"
  end

  def test_no_change_commit_is_success_without_a_push
    # Simulate an idempotent rerun: append_rc will see an existing
    # (sha,key,value) and skip, so commit() has nothing to commit.
    gh = FakeGithub.new
    gh.stub_clone("convos-releases") do |dest|
      mdir = File.join(dest, "releases", "2.1.0")
      FileUtils.mkdir_p(mdir)
      Train::Manifest.init(
        File.join(mdir, "manifest.yml"), version: "2.1.0", kind: "release", cut_date: "2026-07-16",
        repos: { "xmtplabs/convos-ios" => "sha-ios" }
      )
      Train::Manifest.append_rc(
        File.join(mdir, "manifest.yml"), repo: "xmtplabs/convos-ios", sha: "abc123",
        run: "https://run/1", key: "build-number", value: "421"
      )
    end
    def gh.commit(dir, _message, all: false)
      record(:commit, [dir, "no-change"], { all: all })
      false # nothing to commit
    end

    result = new_append(gh).run(**base_args, version: "2.1.0")

    assert_equal Dry::Monads::Success(true), result
    refute gh.called?(:push), "no-change commit must not attempt a push"
  end

  def test_push_contention_retries_with_a_fresh_clone_each_attempt
    @gh.fail_push_times("HEAD:main", 2) # fails twice, succeeds on the 3rd attempt

    result = without_sleep { new_append.run(**base_args, version: "2.1.0") }

    assert_equal Dry::Monads::Success(true), result
    assert_equal 3, @gh.calls_for(:clone).size, "each retry must start from a fresh clone"
    assert_equal 3, @gh.calls_for(:push).size
  end

  def test_push_contention_exhausts_after_three_attempts_with_clear_message
    @gh.fail_push_times("HEAD:main", 99) # never succeeds

    result = without_sleep { new_append.run(**base_args, version: "2.1.0") }

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/push contention/i, result.failure)
    assert_equal 3, @gh.calls_for(:clone).size
    assert_equal 3, @gh.calls_for(:push).size
  end

  def test_clone_command_error_propagates_unchanged_without_retry
    # Only a push failure is PushContention (retried); a clone/config/
    # commit CommandError must propagate unchanged — no retry, and it must
    # NOT be mislabeled as "push contention". fail_clone_times(..., 99)
    # would retry forever under the old blanket-rescue behavior; here it
    # must raise straight out of run() after exactly one attempt.
    @gh.fail_clone_times("convos-releases", 99)

    assert_raises(Train::Github::CommandError) do
      without_sleep { new_append.run(**base_args, version: "2.1.0") }
    end
    assert_equal 1, @gh.calls_for(:clone).size, "clone must not be retried for a non-push CommandError"
  end
end
