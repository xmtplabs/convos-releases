# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "dry/monads"
require "train/merge"
require "train/manifest"
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

  # stub_manifest: registers the convos-releases clone fixture read by
  # Merge#read_manifest — a manifest at `version` with the given `kind` and
  # `repos` (keys become the participating repos). Each repo gets an rc
  # entry for "tip-<repo>" (matching stub_open_release_pr's head-sha) so
  # the RC-presence gate passes by default; override per-repo with `rc:`
  # (repo => sha, nil for no rc entry at all).
  def stub_manifest(gh = @gh, version: VERSION, kind: "release", repos: [IOS, CLIENT], rc: {})
    gh.stub_clone("convos-releases") do |dest|
      mdir = File.join(dest, "releases", version)
      FileUtils.mkdir_p(mdir)
      mfile = File.join(mdir, "manifest.yml")
      Train::Manifest.init(
        mfile, version: version, kind: kind, cut_date: "2026-07-16",
        repos: repos.to_h { |r| [r, "sha-#{r}"] }
      )
      data = Train::Manifest.read(mfile)
      repos.each do |r|
        sha = rc.key?(r) ? rc[r] : "tip-#{r}"
        data["repos"][r]["rc"] = [{ "sha" => sha, "build-number" => 1, "run" => "https://run/1" }] if sha
      end
      Train::Manifest.write(mfile, data)
    end
  end

  # stub_open_release_pr: the common happy-path fixture — an open
  # release/<version> PR on `repo` with the given number, whose tip is
  # "tip-<repo>" (the sha stub_manifest records an rc for).
  def stub_open_release_pr(repo, number, version: VERSION)
    @gh.stub_pr_list(repo: repo, head: "release/#{version}", base: "main", state: "open",
                      result: [{ "number" => number, "url" => "https://x/#{number}", "merged_at" => nil,
                                 "head-sha" => "tip-#{repo}" }])
  end

  def stub_no_release_pr_anywhere(repo, version: VERSION)
    @gh.stub_pr_list(repo: repo, head: "release/#{version}", base: "main", state: "open", result: [])
    @gh.stub_pr_list(repo: repo, head: "release/#{version}", base: "main", state: "all", result: [])
  end

  def both_repos_have_open_release_prs
    stub_manifest
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

  # ---- version format ----

  def test_malformed_version_is_a_failure_before_any_io
    result = new_merge.run(version: "2.1.0/../evil", actor: "octocat")

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/version must look like X\.Y\.Z/, result.failure)
    refute @gh.called?(:clone), "a malformed version must fail before the manifest clone"
  end

  # ---- no manifest for version ----

  def test_no_manifest_for_version_is_a_failure
    @gh.stub_clone("convos-releases") { |dest| FileUtils.mkdir_p(File.join(dest, "releases")) }

    result = new_merge.run(version: VERSION, actor: "octocat")

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/no manifest for #{VERSION}/, result.failure)
    refute @gh.called?(:collaborator_permission), "must not even check permissions without a manifest"
  end

  # ---- manifest-scoped repos: single-platform hotfix ----

  def test_single_repo_manifest_only_attempts_that_repo
    stub_manifest(kind: "hotfix", repos: [IOS])
    @gh.stub_pr_list(repo: IOS, head: "hotfix/#{VERSION}", base: "main", state: "open",
                      result: [{ "number" => 30, "url" => "https://x/30", "merged_at" => nil, "head-sha" => "tip-#{IOS}" }])

    result = new_merge.run(version: VERSION, actor: "octocat")

    assert_equal Dry::Monads::Success(:ok), result
    assert_equal 1, @gh.calls_for(:collaborator_permission).size
    assert_equal 1, @gh.calls_for(:pr_merge).size
    ios_call = @gh.calls_for(:pr_merge).first
    assert_equal IOS, ios_call.args[0]
    assert_equal 30, ios_call.args[1]
  end

  # ---- permission denial: two-phase gate blocks ALL merges ----

  def test_read_only_on_one_repo_fails_that_repo_and_blocks_the_other_from_merging
    stub_manifest
    @gh.stub_permission(IOS, "read")
    stub_open_release_pr(IOS, 10)
    stub_open_release_pr(CLIENT, 20)

    result = new_merge.run(version: VERSION, actor: "someone")

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/#{Regexp.escape(IOS)}.*lacks write.*got read/, result.failure)

    # two-phase gate: BOTH repos' permissions are checked before anything
    # merges, but a failure on either means ZERO merges are attempted
    # anywhere — not even on the repo whose permission passed.
    assert_equal 2, @gh.calls_for(:collaborator_permission).size
    assert_empty @gh.calls_for(:pr_merge), "no merge may be attempted when any repo's permission gate fails"
  end

  def test_permission_denial_message_format
    stub_manifest
    @gh.stub_permission(IOS, "triage")
    stub_open_release_pr(IOS, 10)
    stub_open_release_pr(CLIENT, 20)

    result = new_merge.run(version: VERSION, actor: "bob")

    assert_match(/bob lacks write on #{Regexp.escape(IOS)} \(got triage\)/, result.failure)
  end

  # ---- already merged ----

  def test_one_repo_already_merged_other_merges_overall_success
    stub_manifest
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
    stub_manifest
    stub_no_release_pr_anywhere(IOS)
    stub_open_release_pr(CLIENT, 20)

    result = new_merge.run(version: VERSION, actor: "octocat")

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/no release PR for #{VERSION} on #{Regexp.escape(IOS)}/, result.failure)
  end

  # ---- hotfix kind: branch prefix from manifest, no blind fallback ----

  def test_hotfix_kind_looks_for_hotfix_branch_only
    stub_manifest(kind: "hotfix")
    @gh.stub_pr_list(
      repo: IOS, head: "hotfix/#{VERSION}", base: "main", state: "open",
      result: [{ "number" => 30, "url" => "https://x/30", "merged_at" => nil, "head-sha" => "tip-#{IOS}" }]
    )
    @gh.stub_pr_list(
      repo: CLIENT, head: "hotfix/#{VERSION}", base: "main", state: "open",
      result: [{ "number" => 31, "url" => "https://x/31", "merged_at" => nil, "head-sha" => "tip-#{CLIENT}" }]
    )

    result = new_merge.run(version: VERSION, actor: "octocat")

    assert_equal Dry::Monads::Success(:ok), result
    ios_call = @gh.calls_for(:pr_merge).find { |c| c.args[0] == IOS }
    assert_equal 30, ios_call.args[1]
    assert_match(/#{Regexp.escape(IOS)}: merged #30/, @out.string)
  end

  def test_release_kind_does_not_fall_back_to_hotfix_branch
    # A release-kind manifest must not accidentally match a hotfix/<version>
    # PR left over from an unrelated branch — no blind fallback between the
    # two kinds anymore.
    stub_manifest(kind: "release")
    stub_no_release_pr_anywhere(IOS)
    @gh.stub_pr_list(
      repo: IOS, head: "hotfix/#{VERSION}", base: "main", state: "open",
      result: [{ "number" => 99, "url" => "https://x/99", "merged_at" => nil }]
    )
    stub_open_release_pr(CLIENT, 20)

    result = new_merge.run(version: VERSION, actor: "octocat")

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/no release PR for #{VERSION} on #{Regexp.escape(IOS)}/, result.failure)
    refute @gh.calls_for(:pr_merge).any? { |c| c.args[0] == IOS }
  end

  # ---- RC-presence gate: no merge without an uploaded RC for the tip ----

  def test_no_rc_for_tip_blocks_that_repo_but_not_the_other
    stub_manifest(rc: { IOS => nil })
    stub_open_release_pr(IOS, 10)
    stub_open_release_pr(CLIENT, 20)

    result = new_merge.run(version: VERSION, actor: "octocat")

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/#{Regexp.escape(IOS)}: no RC recorded for tip tip-#{Regexp.escape(IOS)}/, result.failure)
    refute @gh.calls_for(:pr_merge).any? { |c| c.args[0] == IOS }, "an un-RC'd tip must not be merged"
    assert @gh.calls_for(:pr_merge).any? { |c| c.args[0] == CLIENT }, "the RC'd repo must still merge"
  end

  def test_stale_rc_for_an_older_tip_blocks_the_merge
    # RC recorded for an EARLIER push; a later commit moved the tip and its
    # upload hasn't finished.
    stub_manifest(rc: { IOS => "older-tip-sha" })
    stub_open_release_pr(IOS, 10)
    stub_open_release_pr(CLIENT, 20)

    result = new_merge.run(version: VERSION, actor: "octocat")

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/no RC recorded for tip tip-#{Regexp.escape(IOS)}/, result.failure)
    refute @gh.calls_for(:pr_merge).any? { |c| c.args[0] == IOS }
  end

  def test_already_merged_repo_skips_the_rc_gate
    # The gate protects the merge decision — a PR that's already merged
    # has nothing left to gate (promotion does its own RC lookup).
    stub_manifest(rc: { IOS => nil })
    @gh.stub_pr_list(repo: IOS, head: "release/#{VERSION}", base: "main", state: "open", result: [])
    @gh.stub_pr_list(
      repo: IOS, head: "release/#{VERSION}", base: "main", state: "all",
      result: [{ "number" => 5, "url" => "https://x/5", "merged_at" => "2026-07-15T00:00:00Z" }]
    )
    stub_open_release_pr(CLIENT, 20)

    result = new_merge.run(version: VERSION, actor: "octocat")

    assert_equal Dry::Monads::Success(:ok), result
  end

  # ---- API errors fold into Results, never crash the run ----

  def test_permission_api_error_is_a_gate_failure_with_zero_merges
    both_repos_have_open_release_prs
    @gh.fail_collaborator_permission(IOS, message: "boom 500")

    result = new_merge.run(version: VERSION, actor: "octocat")

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/#{Regexp.escape(IOS)}: permission check failed: boom 500/, result.failure)
    assert_empty @gh.calls_for(:pr_merge), "an API error in the gate must block all merges"
  end

  def test_pr_lookup_api_error_is_that_repos_failure_other_repo_still_merges
    both_repos_have_open_release_prs
    @gh.fail_pr_list(IOS, message: "boom 502")

    result = new_merge.run(version: VERSION, actor: "octocat")

    assert_instance_of Dry::Monads::Result::Failure, result
    assert_match(/#{Regexp.escape(IOS)}: boom 502/, result.failure)
    assert @gh.calls_for(:pr_merge).any? { |c| c.args[0] == CLIENT }, "other repo must still be attempted"
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
    stub_manifest(gh)
    gh.stub_pr_list(repo: IOS, head: "release/#{VERSION}", base: "main", state: "open",
                     result: [{ "number" => 10, "url" => "https://x/10", "merged_at" => nil, "head-sha" => "tip-#{IOS}" }])
    gh.stub_pr_list(repo: CLIENT, head: "release/#{VERSION}", base: "main", state: "open",
                     result: [{ "number" => 20, "url" => "https://x/20", "merged_at" => nil, "head-sha" => "tip-#{CLIENT}" }])

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
