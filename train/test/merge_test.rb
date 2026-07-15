# frozen_string_literal: true

require_relative "test_helper"
require "dry/monads"
require "train/merge"
require_relative "support/fake_github"

class MergeTest < Minitest::Test
  IOS = "xmtplabs/convos-ios"
  CLIENT = "xmtplabs/convos-client"
  VERSION = "2.1.0"

  def setup
    @out = StringIO.new
    @gh = FakeGithub.new
  end

  def new_merge(gh = @gh)
    Train::Merge.new(github: gh, out: @out)
  end

  # stub_open_release_pr: the common happy-path fixture — an open
  # release/<version> PR on `repo` with the given number.
  def stub_open_release_pr(repo, number, version: VERSION)
    @gh.stub_pr_list(repo: repo, head: "release/#{version}", base: "main", state: "open",
                      result: [{ "number" => number, "url" => "https://x/#{number}", "merged_at" => nil }])
  end

  def stub_no_release_pr_anywhere(repo, version: VERSION)
    @gh.stub_pr_list(repo: repo, head: "release/#{version}", base: "main", state: "open", result: [])
    @gh.stub_pr_list(repo: repo, head: "release/#{version}", base: "main", state: "all", result: [])
    @gh.stub_pr_list(repo: repo, head: "hotfix/#{version}", base: "main", state: "open", result: [])
    @gh.stub_pr_list(repo: repo, head: "hotfix/#{version}", base: "main", state: "all", result: [])
  end

  def both_repos_have_open_release_prs
    stub_open_release_pr(IOS, 10)
    stub_open_release_pr(CLIENT, 20)
  end

  # ---- happy path: both repos merged ----

  def test_both_repos_merged_with_merge_method_merge
    both_repos_have_open_release_prs

    result = new_merge.run(version: VERSION, actor: "octocat")

    assert_equal Dry::Monads::Success(:ok), result

    merge_calls = @gh.calls_for(:pr_merge)
    assert_equal 2, merge_calls.size

    ios_call = merge_calls.find { |c| c.args[0] == IOS }
    assert_equal 10, ios_call.args[1]
    assert_equal "merge", ios_call.kwargs[:merge_method]

    client_call = merge_calls.find { |c| c.args[0] == CLIENT }
    assert_equal 20, client_call.args[1]
    assert_equal "merge", client_call.kwargs[:merge_method]

    assert_match(/#{Regexp.escape(IOS)}: merged #10/, @out.string)
    assert_match(/#{Regexp.escape(CLIENT)}: merged #20/, @out.string)
  end

  def test_checks_permission_once_per_repo
    both_repos_have_open_release_prs

    new_merge.run(version: VERSION, actor: "octocat")

    perm_calls = @gh.calls_for(:collaborator_permission)
    assert_equal 2, perm_calls.size
    assert_equal [IOS, "octocat"], perm_calls.find { |c| c.args[0] == IOS }.args
    assert_equal [CLIENT, "octocat"], perm_calls.find { |c| c.args[0] == CLIENT }.args
  end

  # ---- permission denial: other repo still attempted ----

  def test_read_only_on_one_repo_fails_that_repo_but_still_attempts_the_other
    @gh.stub_permission(IOS, "read")
    both_repos_have_open_release_prs

    result = new_merge.run(version: VERSION, actor: "someone")

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/#{Regexp.escape(IOS)}.*lacks write.*got read/, result.failure)

    # the other repo's merge must still have been attempted
    assert @gh.calls_for(:pr_merge).any? { |c| c.args[0] == CLIENT }
    refute @gh.calls_for(:pr_merge).any? { |c| c.args[0] == IOS }, "permission-denied repo must not be merged"
  end

  def test_permission_denial_message_format
    @gh.stub_permission(IOS, "triage")
    both_repos_have_open_release_prs

    result = new_merge.run(version: VERSION, actor: "bob")

    assert_match(/bob lacks write on #{Regexp.escape(IOS)} \(got triage\)/, result.failure)
  end

  # ---- already merged ----

  def test_one_repo_already_merged_other_merges_overall_success
    @gh.stub_pr_list(repo: IOS, head: "release/#{VERSION}", base: "main", state: "open", result: [])
    @gh.stub_pr_list(
      repo: IOS, head: "release/#{VERSION}", base: "main", state: "all",
      result: [{ "number" => 5, "url" => "https://x/5", "merged_at" => "2026-07-15T00:00:00Z" }]
    )
    stub_open_release_pr(CLIENT, 20)

    result = new_merge.run(version: VERSION, actor: "octocat")

    assert_equal Dry::Monads::Success(:ok), result
    refute @gh.calls_for(:pr_merge).any? { |c| c.args[0] == IOS }, "an already-merged PR must not be re-merged"
    assert @gh.calls_for(:pr_merge).any? { |c| c.args[0] == CLIENT }
    assert_match(/#{Regexp.escape(IOS)}: already merged/, @out.string)
  end

  # ---- no PR anywhere ----

  def test_no_pr_anywhere_for_the_version_fails_naming_the_repo
    stub_no_release_pr_anywhere(IOS)
    stub_open_release_pr(CLIENT, 20)

    result = new_merge.run(version: VERSION, actor: "octocat")

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/no release PR for #{VERSION} on #{Regexp.escape(IOS)}/, result.failure)
  end

  # ---- hotfix fallback ----

  def test_hotfix_fallback_when_release_branch_pr_absent
    @gh.stub_pr_list(repo: IOS, head: "release/2.1.1", base: "main", state: "open", result: [])
    @gh.stub_pr_list(repo: IOS, head: "release/2.1.1", base: "main", state: "all", result: [])
    @gh.stub_pr_list(
      repo: IOS, head: "hotfix/2.1.1", base: "main", state: "open",
      result: [{ "number" => 30, "url" => "https://x/30", "merged_at" => nil }]
    )
    stub_open_release_pr(CLIENT, 20, version: "2.1.1")

    result = new_merge.run(version: "2.1.1", actor: "octocat")

    assert_equal Dry::Monads::Success(:ok), result
    ios_call = @gh.calls_for(:pr_merge).find { |c| c.args[0] == IOS }
    assert_equal 30, ios_call.args[1]
    assert_match(/#{Regexp.escape(IOS)}: merged #30/, @out.string)
  end

  # ---- merge API failure ----

  def test_merge_api_failure_is_reported_for_that_repo_only
    both_repos_have_open_release_prs
    @gh.fail_pr_merge(IOS, 10, message: "merge conflict")

    result = new_merge.run(version: VERSION, actor: "octocat")

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/#{Regexp.escape(IOS)}: merge conflict/, result.failure)
    assert @gh.calls_for(:pr_merge).any? { |c| c.args[0] == CLIENT }, "other repo must still be attempted"
  end

  # ---- dry-run ----

  def test_dry_run_runs_permission_and_lookup_but_does_not_actually_merge
    gh = FakeGithub.new(dry_run: true)
    gh.stub_pr_list(repo: IOS, head: "release/#{VERSION}", base: "main", state: "open",
                     result: [{ "number" => 10, "url" => "https://x/10", "merged_at" => nil }])
    gh.stub_pr_list(repo: CLIENT, head: "release/#{VERSION}", base: "main", state: "open",
                     result: [{ "number" => 20, "url" => "https://x/20", "merged_at" => nil }])

    result = new_merge(gh).run(version: VERSION, actor: "octocat")

    assert_equal Dry::Monads::Success(:ok), result
    assert_equal 2, gh.calls_for(:collaborator_permission).size
    assert_equal 2, gh.calls_for(:pr_list).count { |c| c.kwargs[:state] == "open" }
    # pr_merge is still CALLED (mutate! gate lives inside Github#pr_merge,
    # which the fake doesn't model with a real no-op branch) — the seam's
    # actual dry-run contract is asserted in github_test.rb; here it's
    # enough that Merge never special-cases dry_run itself and the overall
    # result is Success.
  end
end
