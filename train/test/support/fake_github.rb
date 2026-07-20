# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "train/github"

# A Github test double: records every call (for assertions) and lets tests
# script canned responses, so nothing touches the network or a real git
# binary. clone() materializes a directory with a version fixture file, since
# callers immediately Versions.read/bump against it.
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
    @pushes_fail = {}       # dir_suffix => true/false
    @push_fail_countdown = Hash.new(0) # refspec => remaining failures before success
    @push_fail_from_call = {} # dir_suffix => 1-indexed call number to start failing at
    @push_call_count = Hash.new(0) # dir_suffix => calls seen so far
    @clone_error_countdown = Hash.new(0) # url-substring => remaining CommandErrors before success
    @pr_merge_results = Hash.new(true)
    @releases = {} # [repo, tag] => true
    @release_bodies = {} # [repo, tag] => body
    @pr_comments = [] # [{repo:, number:, body:}]
    @permissions = Hash.new("write") # repo => permission (default: write)
    @pr_merge_failures = {} # [repo, number] => message
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

  def stub_tag_sha(tag, sha)
    @tag_shas ||= {}
    @tag_shas[tag] = sha
  end

  # stub_latest_tag: scripts latest_tag(dir, pattern) for the clone whose
  # directory basename is `dir_suffix`.
  def stub_latest_tag(dir_suffix, tag)
    @latest_tags ||= {}
    @latest_tags[dir_suffix] = tag
  end

  # Scripts ancestor? to return false for this clone; tests default to true.
  def stub_not_ancestor(dir_suffix)
    (@not_ancestors ||= {})[dir_suffix] = true
  end

  def stub_rev_parse(dir_suffix, ref, sha)
    @rev_parses ||= {}
    @rev_parses[[dir_suffix, ref]] = sha
  end

  def stub_pr_list(repo:, head: nil, base: nil, state: "open", result:)
    @pr_lists[[repo, head, base, state]] = result
  end

  def fail_push(dir_suffix)
    @pushes_fail[dir_suffix] = true
  end

  # fail_push_from_call(dir_suffix, n): push() calls against this clone's
  # directory succeed until the n-th call (1-indexed), which and all
  # subsequent calls fail. Lets a test target persist_statuses' push
  # specifically without also failing an earlier push (e.g. the initial
  # manifest commit) that shares the same dir and refspec.
  def fail_push_from_call(dir_suffix, n)
    @push_fail_from_call[dir_suffix] = n
  end

  # The next `n` push() calls with this exact `refspec` fail, then succeed.
  # Keyed on refspec since a fresh-clone-per-attempt caller pushes from a new
  # tmpdir each retry. Exercises "retry then succeed".
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

  # fail_commit: subsequent commit() calls whose message contains `match`
  # raise Train::Github::CommandError instead of committing — simulates a
  # git commit failure inside persist_statuses' best-effort status/anchor
  # persist without disturbing unrelated commits (e.g. the initial manifest
  # commit) that share the same fake.
  def fail_commit(match: "repo statuses", message: "simulated commit failure")
    @commit_failure = { match: match, message: message }
  end

  # stub_release_exists: scripts release_exists?(repo, tag) to return true
  # — tests default to "absent" (false) unless a release is stubbed here.
  def stub_release_exists(repo, tag)
    @releases[[repo, tag]] = true
  end

  # stub_permission: scripts collaborator_permission(repo, login) to return
  # `permission` — tests default to "write" (allowed) unless overridden.
  def stub_permission(repo, permission)
    @permissions[repo] = permission
  end

  # fail_pr_merge: every subsequent pr_merge(repo, number) call raises
  # Train::Github::ApiError with `message` instead of recording a merge.
  def fail_pr_merge(repo, number, message: "simulated merge failure")
    @pr_merge_failures[[repo, number]] = message
  end

  # fail_collaborator_permission: every subsequent
  # collaborator_permission(repo, ...) call raises Train::Github::ApiError.
  def fail_collaborator_permission(repo, message: "simulated permission API failure")
    (@permission_failures ||= {})[repo] = message
  end

  # fail_pr_list: every subsequent pr_list(repo: repo, ...) call raises
  # Train::Github::ApiError.
  def fail_pr_list(repo, message: "simulated pr list API failure")
    (@pr_list_failures ||= {})[repo] = message
  end

  # stub_branch_missing: scripts branch_exists?(repo, branch) to return
  # false — tests default to true (the branch survived its PR's merge).
  def stub_branch_missing(repo, branch)
    (@missing_branches ||= {})[[repo, branch]] = true
  end

  # ---- Github interface ----

  def ls_remote(dir, ref)
    record(:ls_remote, [dir, ref])
    @ls_remote[[suffix(dir), ref]] || ""
  end

  def rev_parse(dir, ref = "HEAD")
    record(:rev_parse, [dir, ref])
    @rev_parses ||= {}
    @rev_parses[[suffix(dir), ref]] || @rev_parses[suffix(dir)] || "sha-#{suffix(dir)}"
  end

  # tag_sha: resolves refs/tags/<tag> on origin — "" when the tag doesn't
  # exist. Scriptable via stub_tag_sha; always read-only.
  def tag_sha(dir, tag)
    record(:tag_sha, [dir, tag])
    @tag_shas ||= {}
    @tag_shas[tag] || ""
  end

  # latest_tag: read-only, scriptable via stub_latest_tag; defaults to "" (no
  # matching tag) for any clone not explicitly stubbed.
  def latest_tag(dir, pattern)
    record(:latest_tag, [dir, pattern])
    @latest_tags ||= {}
    @latest_tags[suffix(dir)] || ""
  end

  # ancestor?: read-only, defaults to true unless scripted via
  # stub_not_ancestor for this clone's directory basename.
  def ancestor?(dir, ancestor, descendant)
    record(:ancestor?, [dir, ancestor, descendant])
    !(@not_ancestors || {})[suffix(dir)]
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

  # releases_clone_url / with_releases_clone: mirror the real seam so the
  # read-only convos-releases readers (Merge/Promote) route through the same
  # tmpdir + clone + cleanup lifecycle; the URL keeps the "convos-releases"
  # substring stub_clone matches on.
  def releases_clone_url
    "https://x-access-token:token@github.com/xmtplabs/convos-releases.git"
  end

  def with_releases_clone(prefix)
    dir = Dir.mktmpdir(prefix)
    begin
      clone(releases_clone_url, dir, depth: 1)
      yield dir
    ensure
      FileUtils.remove_entry(dir) if Dir.exist?(dir)
    end
  end

  def checkout(dir, ref)
    record(:checkout, [dir, ref])
  end

  def checkout_branch(dir, branch, sha)
    record(:checkout_branch, [dir, branch, sha])
  end

  def pr_list(repo:, head: nil, base: nil, state: "open")
    record(:pr_list, [], { repo: repo, head: head, base: base, state: state })
    if @pr_list_failures&.key?(repo)
      raise ::Train::Github::ApiError, @pr_list_failures[repo]
    end

    @pr_lists[[repo, head, base, state]]
  end

  def merged_prs_since(repo, since)
    record(:merged_prs_since, [repo, since])
    []
  end

  def git_config_bot(dir)
    record(:git_config_bot, [dir])
  end

  def add(dir, path)
    record(:add, [dir, path])
  end

  def commit(dir, message, all: false)
    record(:commit, [dir, message], { all: all })
    if @commit_failure && message.include?(@commit_failure[:match])
      raise ::Train::Github::CommandError.new(
        ["git", "commit", "-m", message], stdout: "", stderr: @commit_failure[:message], status: fake_failed_status
      )
    end

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

    @push_call_count[suffix(dir)] += 1
    from_call = @push_fail_from_call[suffix(dir)]
    return false if from_call && @push_call_count[suffix(dir)] >= from_call

    true
  end

  def set_remote_url(dir, url)
    record(:set_remote_url, [dir, url])
  end

  # reset_hard: best-effort recovery from a failed persist push — resets
  # @releases_dir back to `ref` so a stranded local commit can't wedge the
  # next run's guard_synced_checkout.
  def reset_hard(dir, ref)
    record(:reset_hard, [dir, ref])
    if (@reset_hard_failures ||= {})[suffix(dir)]
      raise ::Train::Github::CommandError.new(
        ["git", "reset", "--hard", ref], stdout: "", stderr: @reset_hard_failures[suffix(dir)], status: fake_failed_status
      )
    end
  end

  # fail_reset_hard: the next reset_hard(dir, ...) call for this clone's
  # directory basename raises Train::Github::CommandError instead of
  # resetting — simulates reset_hard itself failing.
  def fail_reset_hard(dir_suffix, message: "simulated reset failure")
    (@reset_hard_failures ||= {})[dir_suffix] = message
  end

  # fetch: best-effort recovery step before reset_hard — pulls `refspec`'s
  # objects into the local clone so a subsequent reset to FETCH_HEAD can
  # succeed even when ls_remote's reported sha isn't present locally yet.
  def fetch(dir, refspec)
    record(:fetch, [dir, refspec])
    if (@fetch_failures ||= {})[suffix(dir)]
      raise ::Train::Github::CommandError.new(
        ["git", "fetch", "origin", refspec], stdout: "", stderr: @fetch_failures[suffix(dir)], status: fake_failed_status
      )
    end
  end

  # fail_fetch: the next fetch(dir, ...) call for this clone's directory
  # basename raises Train::Github::CommandError instead of fetching.
  def fail_fetch(dir_suffix, message: "simulated fetch failure")
    (@fetch_failures ||= {})[dir_suffix] = message
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

  # collaborator_permission: read-only, so it always executes (dry-run or
  # not), matching the real Github#collaborator_permission.
  def collaborator_permission(repo, login)
    record(:collaborator_permission, [repo, login])
    if @permission_failures&.key?(repo)
      raise ::Train::Github::ApiError, @permission_failures[repo]
    end

    @permissions[repo]
  end

  # Records the call (even under dry-run, like push/commit); recording IS the
  # observable effect tests assert against.
  def pr_merge(repo, number, merge_method: "merge", expected_head_sha: nil)
    record(:pr_merge, [repo, number], { merge_method: merge_method, expected_head_sha: expected_head_sha })
    if @pr_merge_failures.key?([repo, number])
      raise ::Train::Github::ApiError, @pr_merge_failures[[repo, number]]
    end

    true
  end

  # release_exists?: read-only, so it always executes (dry-run or not),
  # matching the real Github#release_exists? — Promote#record needs the
  # true answer under dry-run too.
  def release_exists?(repo, tag)
    record(:release_exists?, [repo, tag])
    @releases[[repo, tag]] || false
  end

  # branch_exists?: read-only; defaults to true unless scripted via
  # stub_branch_missing. create_ref flips it back to true so an
  # ensure-state restore-then-recheck converges like the real seam.
  def branch_exists?(repo, branch)
    record(:branch_exists?, [repo, branch])
    !(@missing_branches || {})[[repo, branch]]
  end

  def create_ref(repo, branch:, sha:)
    record(:create_ref, [repo], { branch: branch, sha: sha })
    return if @dry_run

    (@missing_branches || {}).delete([repo, branch])
  end

  def create_release(repo, tag:, name:, body:)
    record(:create_release, [repo], { tag: tag, name: name, body: body })
    return if @dry_run

    @releases[[repo, tag]] = true
    @release_bodies[[repo, tag]] = body
  end

  def pr_comment(repo, number, body)
    record(:pr_comment, [repo, number, body])
    @pr_comments << { repo: repo, number: number, body: body } unless @dry_run
  end

  def release_body(repo, tag)
    @release_bodies[[repo, tag]]
  end

  def pr_comments_for(repo, number)
    @pr_comments.select { |c| c[:repo] == repo && c[:number] == number }
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
