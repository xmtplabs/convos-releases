# frozen_string_literal: true

require "fileutils"
require "train/github"

# FakeGithub: a Github test double. Cut tests inject one of these instead
# of the real Train::Github so nothing touches the network or a real gh/git
# binary. It records every call (for assertions) and lets tests script
# canned responses (e.g. "ios repo is at this dev sha/version").
#
# clone() is faked by materializing a directory with a version fixture
# file, since Cut#run immediately calls Versions.read/bump against
# whatever clone() returns — a real `git clone` isn't available/desired in
# unit tests.
class FakeGithub
  Call = Struct.new(:method, :args, :kwargs, keyword_init: false)

  attr_reader :calls
  attr_accessor :dry_run

  def initialize(dry_run: false)
    @dry_run = dry_run
    @calls = []
    @clone_fixtures = {}   # url-substring => proc(dest)
    @ls_remote = {}        # [dir_suffix, ref] => sha ("" for absent)
    @pr_lists = Hash.new { |h, k| h[k] = [] } # [repo, head, base, state] => [{...}]
    @tags = {}              # dir_suffix => [tags]
    @commit_dates = {}      # [dir_suffix, ref] => date
    @pushes_fail = {}       # dir_suffix => true/false
    @push_fail_countdown = Hash.new(0) # refspec => remaining failures before success
    @clone_error_countdown = Hash.new(0) # url-substring => remaining CommandErrors before success
    @pr_merge_results = Hash.new(true)
  end

  # ---- test scripting API ----

  # Registers a fixture writer for clone(url, dest): whenever `url`
  # contains `match`, `writer.call(dest)` populates dest instead of a real
  # git clone.
  def stub_clone(match, &writer)
    @clone_fixtures[match] = writer
  end

  def stub_ls_remote(dir_suffix, ref, sha)
    @ls_remote[[dir_suffix, ref]] = sha
  end

  def stub_pr_list(repo:, head: nil, base: nil, state: "open", result:)
    @pr_lists[[repo, head, base, state]] = result
  end

  def stub_tags(dir_suffix, tags)
    @tags[dir_suffix] = tags
  end

  def stub_commit_date(dir_suffix, ref, date)
    @commit_dates[[dir_suffix, ref]] = date
  end

  def stub_merged_prs(repo, prs)
    (@merged_prs ||= {})[repo] = prs
  end

  def fail_push(dir_suffix)
    @pushes_fail[dir_suffix] = true
  end

  # fail_push_times: the next `n` push() calls with this exact `refspec`
  # fail (return false); calls after that succeed. Keyed on refspec rather
  # than dir, since a fresh-clone-per-attempt caller (e.g. Append) pushes
  # from a different tmpdir on every retry. Lets tests exercise "retry then
  # succeed" without a permanent failure.
  def fail_push_times(refspec, n)
    @push_fail_countdown[refspec] = n
  end

  # fail_clone_times: the next `n` clone() calls whose url contains `match`
  # raise Train::Github::CommandError; calls after that succeed normally.
  def fail_clone_times(match, n)
    @clone_error_countdown[match] = n
  end

  # fail_pr_create: every subsequent pr_create() call for `repo` raises
  # Train::Github::ApiError instead of returning normally — simulates a
  # GitHub API failure inside the best-effort bump-PR/release-PR steps.
  def fail_pr_create(repo, message: "simulated API failure")
    (@pr_create_failures ||= {})[repo] = message
  end

  # ---- Github interface ----

  def ls_remote(dir, ref)
    record(:ls_remote, [dir, ref])
    @ls_remote[[suffix(dir), ref]] || ""
  end

  def rev_parse(dir, ref = "HEAD")
    record(:rev_parse, [dir, ref])
    @rev_parses ||= {}
    @rev_parses[suffix(dir)] || "sha-#{suffix(dir)}"
  end

  def clone(url, dest, depth: nil, filter: nil)
    record(:clone, [url, dest], { depth: depth, filter: filter })
    match = @clone_error_countdown.keys.find { |m| url.include?(m) }
    if match && @clone_error_countdown[match].positive?
      @clone_error_countdown[match] -= 1
      raise ::Train::Github::CommandError.new(
        ["git", "clone", url, dest], stdout: "", stderr: "transient clone failure", status: fake_failed_status
      )
    end

    FileUtils.mkdir_p(dest)
    writer = @clone_fixtures.find { |m, _| url.include?(m) }&.last
    writer&.call(dest)
    dest
  end

  def checkout(dir, ref)
    record(:checkout, [dir, ref])
  end

  def checkout_branch(dir, branch, sha)
    record(:checkout_branch, [dir, branch, sha])
  end

  def tags(dir, pattern)
    record(:tags, [dir, pattern])
    @tags[suffix(dir)] || []
  end

  def commit_date(dir, ref)
    record(:commit_date, [dir, ref])
    @commit_dates[[suffix(dir), ref]] || "2026-01-01"
  end

  def pr_list(repo:, head: nil, base: nil, state: "open")
    record(:pr_list, [], { repo: repo, head: head, base: base, state: state })
    @pr_lists[[repo, head, base, state]]
  end

  def merged_prs_since(repo, since)
    record(:merged_prs_since, [repo, since])
    (@merged_prs || {})[repo] || []
  end

  def git_config_bot(dir)
    record(:git_config_bot, [dir])
  end

  def add(dir, path)
    record(:add, [dir, path])
  end

  def commit(dir, message, all: false)
    record(:commit, [dir, message], { all: all })
    true
  end

  def push(dir, refspec, force: false)
    record(:push, [dir, refspec], { force: force })
    return true if @dry_run
    return false if @pushes_fail[suffix(dir)]

    if @push_fail_countdown[refspec].positive?
      @push_fail_countdown[refspec] -= 1
      return false
    end

    true
  end

  def set_remote_url(dir, url)
    record(:set_remote_url, [dir, url])
  end

  def pr_create(repo:, base:, head:, title:, body:)
    record(:pr_create, [], { repo: repo, base: base, head: head, title: title, body: body })
    if @pr_create_failures&.key?(repo)
      raise ::Train::Github::ApiError, @pr_create_failures[repo]
    end
  end

  def pr_merge_auto(repo:, head_or_number:)
    record(:pr_merge_auto, [], { repo: repo, head_or_number: head_or_number })
    @pr_merge_results[[repo, head_or_number]]
  end

  def dirty?(dir, path)
    record(:dirty?, [dir, path])
    @dirty.nil? ? true : @dirty
  end

  def set_dirty(value)
    @dirty = value
  end

  # ---- assertion helpers ----

  def called?(method)
    @calls.any? { |c| c.method == method }
  end

  def calls_for(method)
    @calls.select { |c| c.method == method }
  end

  private

  def record(method, args, kwargs = {})
    @calls << Call.new(method, args, kwargs)
  end

  FakeStatus = Struct.new(:success?)
  private_constant :FakeStatus

  def fake_failed_status
    FakeStatus.new(false)
  end

  def suffix(dir)
    File.basename(dir)
  end
end
