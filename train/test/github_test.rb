# frozen_string_literal: true

require_relative "test_helper"
require "train/github"

# FakeOctokitClient: a minimal Octokit::Client double. Real Octokit calls
# return Sawyer::Resource objects (Hash-ish: [] with symbol keys, #dig);
# plain Hashes support the same [] / dig interface, so hashes with symbol
# keys stand in fine here without pulling in Sawyer.
class FakeOctokitClient
  attr_reader :posts

  def initialize
    @posts = []
    @pull_requests = Hash.new { |h, k| h[k] = [] } # [repo, head, state] => [pr, ...]
    @pull_request_by_number = {}
    @search_results = Hash.new([])                # query => [item, ...]
    @create_result = nil
    @graphql_result = { errors: nil }
  end

  def stub_pull_requests(repo:, head: nil, state: "open", result:)
    @pull_requests[[repo, head, state]] = result
  end

  def stub_pull_request(repo:, number:, result:)
    @pull_request_by_number[[repo, number]] = result
  end

  def stub_search_issues(query, items)
    @search_results[query] = items
  end

  def stub_create_pull_request(result)
    @create_result = result
  end

  def stub_graphql_result(result)
    @graphql_result = result
  end

  def pull_requests(repo, options = {})
    @pull_requests[[repo, options[:head], options[:state] || "open"]]
  end

  def pull_request(repo, number, _options = {})
    @pull_request_by_number[[repo, number]]
  end

  def create_pull_request(repo, base, head, title, body = nil, _options = {})
    @last_create = { repo: repo, base: base, head: head, title: title, body: body }
    @create_result
  end

  def search_issues(query, _options = {})
    { items: @search_results[query] }
  end

  def post(url, body)
    @posts << { url: url, body: body }
    @graphql_result
  end
end

class GithubTest < Minitest::Test
  def setup
    @out = StringIO.new
  end

  # ---- CommandError: token redaction ----

  FakeFailedStatus = Struct.new(:success?) do
    def to_s
      "exit 128"
    end
  end
  private_constant :FakeFailedStatus

  def test_command_error_redacts_token_url_from_message
    token = "ghs_supersecrettoken1234567890"
    cmd = ["git", "clone", "--quiet", "https://x-access-token:#{token}@github.com/xmtplabs/convos-releases.git", "dest"]

    error = assert_raises(Train::Github::CommandError) do
      raise Train::Github::CommandError.new(cmd, stdout: "", stderr: "fatal: authentication failed", status: FakeFailedStatus.new(false))
    end

    assert_includes error.message, "<redacted>"
    refute_includes error.message, token
  end

  # ---- dry-run: must never touch Octokit ----

  def test_dry_run_short_circuits_before_client_instantiation
    ENV.delete("GH_TOKEN")
    gh = Train::Github.new(dry_run: true, out: @out)

    # No GH_TOKEN, and no injected client — if any of these reached a real
    # Octokit::Client.new(access_token: ENV.fetch("GH_TOKEN")), it would
    # raise KeyError. Reaching `true`/nil back out proves the dry-run gate
    # short-circuited before Octokit was ever touched.
    assert_nil gh.pr_create(repo: "o/r", base: "main", head: "feat", title: "t", body: "b")
    assert_equal true, gh.pr_merge_auto(repo: "o/r", head_or_number: "feat")
    assert_match(/\[dry-run\] create PR/, @out.string)
    assert_match(/\[dry-run\] enable auto-merge/, @out.string)
  end

  # ---- pr_list: normalizes Octokit results to string-keyed hashes ----

  def test_pr_list_normalizes_to_string_keyed_hashes
    client = FakeOctokitClient.new
    client.stub_pull_requests(
      repo: "o/r", head: "o:bot/bump-1.2.0", state: "all",
      result: [{ number: 42, html_url: "https://github.com/o/r/pull/42" }]
    )
    gh = Train::Github.new(client: client)

    result = gh.pr_list(repo: "o/r", head: "bot/bump-1.2.0", state: "all")

    assert_equal [{ "number" => 42, "url" => "https://github.com/o/r/pull/42" }], result
  end

  def test_pr_list_empty_when_no_match
    client = FakeOctokitClient.new
    gh = Train::Github.new(client: client)

    assert_empty gh.pr_list(repo: "o/r", head: "nope", state: "open")
  end

  # ---- merged_prs_since: search_issues, bot-filter shape ----

  def test_merged_prs_since_normalizes_and_flags_bots
    client = FakeOctokitClient.new
    query = "repo:o/r is:pr base:dev is:merged merged:>=2026-01-01"
    client.stub_search_issues(query, [
      { number: 1, title: "feat: real feature", user: { type: "User" } },
      { number: 2, title: "chore: bump deps", user: { type: "Bot" } }
    ])
    gh = Train::Github.new(client: client)

    prs = gh.merged_prs_since("o/r", "2026-01-01")

    assert_equal 2, prs.size
    assert_equal({ "number" => 1, "title" => "feat: real feature", "author" => { "is_bot" => false } }, prs[0])
    assert_equal({ "number" => 2, "title" => "chore: bump deps", "author" => { "is_bot" => true } }, prs[1])
  end

  # ---- pr_create ----

  def test_pr_create_returns_normalized_result
    client = FakeOctokitClient.new
    client.stub_create_pull_request({ number: 7, html_url: "https://github.com/o/r/pull/7" })
    gh = Train::Github.new(client: client)

    result = gh.pr_create(repo: "o/r", base: "main", head: "feat", title: "t", body: "b")

    assert_equal({ "number" => 7, "url" => "https://github.com/o/r/pull/7" }, result)
  end

  # ---- pr_merge_auto: resolves node_id then posts the GraphQL mutation ----

  def test_pr_merge_auto_by_head_resolves_pr_then_enables_auto_merge
    client = FakeOctokitClient.new
    client.stub_pull_requests(
      repo: "o/r", head: "o:bot/bump-1.2.0", state: "open",
      result: [{ number: 9, node_id: "PR_kwabc", html_url: "x" }]
    )
    client.stub_graphql_result({ data: { enablePullRequestAutoMerge: { pullRequest: { id: "PR_kwabc" } } } })
    gh = Train::Github.new(client: client)

    ok = gh.pr_merge_auto(repo: "o/r", head_or_number: "bot/bump-1.2.0")

    assert_equal true, ok
    assert_equal 1, client.posts.size
    assert_equal "/graphql", client.posts.first[:url]
    assert_includes client.posts.first[:body], "PR_kwabc"
    assert_includes client.posts.first[:body], "enablePullRequestAutoMerge"
  end

  def test_pr_merge_auto_by_number_resolves_pr_then_enables_auto_merge
    client = FakeOctokitClient.new
    client.stub_pull_request(repo: "o/r", number: 9, result: { number: 9, node_id: "PR_kwxyz", html_url: "x" })
    client.stub_graphql_result({ data: { enablePullRequestAutoMerge: { pullRequest: { id: "PR_kwxyz" } } } })
    gh = Train::Github.new(client: client)

    ok = gh.pr_merge_auto(repo: "o/r", head_or_number: 9)

    assert_equal true, ok
    assert_includes client.posts.first[:body], "PR_kwxyz"
  end

  def test_pr_merge_auto_returns_false_with_warning_when_pr_not_found
    client = FakeOctokitClient.new
    gh = Train::Github.new(client: client, out: @out)

    ok = gh.pr_merge_auto(repo: "o/r", head_or_number: "missing-branch")

    assert_equal false, ok
    assert_match(/warning.*not found/i, @out.string)
    assert_empty client.posts
  end

  def test_pr_merge_auto_returns_false_with_warning_on_graphql_errors
    client = FakeOctokitClient.new
    client.stub_pull_requests(
      repo: "o/r", head: "o:feat", state: "open",
      result: [{ number: 9, node_id: "PR_x", html_url: "x" }]
    )
    client.stub_graphql_result({ errors: [{ message: "auto-merge is not allowed for this repository" }] })
    gh = Train::Github.new(client: client, out: @out)

    ok = gh.pr_merge_auto(repo: "o/r", head_or_number: "feat")

    assert_equal false, ok
    assert_match(/warning.*auto-merge failed/i, @out.string)
    assert_match(/not allowed/, @out.string)
  end
end
