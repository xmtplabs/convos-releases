# frozen_string_literal: true

require "open3"
require "json"
require "fileutils"
require "tmpdir"

module Train
  # ALL git subprocess and GitHub API calls live here. Dry-run is enforced
  # centrally: every mutating method goes through mutate! (or api!), so a
  # missed check can't silently mutate state.
  #
  # Git plumbing runs on `git` via Open3; API calls (PR list/create/merge)
  # go through Octokit rather than the `gh` CLI.
  class Github
    class CommandError < StandardError
      attr_reader :stdout, :stderr, :status

      def initialize(cmd, stdout:, stderr:, status:)
        @stdout = stdout
        @stderr = stderr
        @status = status
        redacted_cmd = cmd.map { |arg| self.class.redact(arg) }
        # stderr needs the same treatment as argv: git failures echo the
        # remote URL ("fatal: unable to access 'https://token@...'").
        super("command failed (#{status}): #{redacted_cmd.join(" ")}\n#{self.class.redact(stderr.to_s)}")
      end

      # Strips userinfo (e.g. x-access-token:<TOKEN>) from any URL in the text
      # so failed clone/push commands never leak the token into logs.
      def self.redact(arg)
        arg.gsub(%r{//[^/@\s]+@}, "//<redacted>@")
      end
    end

    # ApiError: raised for GitHub API failures (Octokit::Error and
    # friends), normalized to the tool's own error type so callers don't
    # need to know or rescue Octokit internals directly.
    class ApiError < StandardError
      def initialize(message, cause: nil)
        super(message)
        @cause = cause
      end
    end

    # The identity every train-made commit is authored as (see git_config_bot).
    # Single source of truth so the back-merge gate can recognize train's own
    # commits without a second, drift-prone copy of the literal.
    BOT_AUTHOR_NAME = "convos-conductor"
    BOT_AUTHOR_EMAIL = "convos-conductor[bot]@users.noreply.github.com"

    attr_reader :dry_run

    # client: optional Octokit::Client (or test double) injection point.
    # Left nil in production — the real client is built lazily on first
    # use so dry-run/no-token paths never touch Octokit at all.
    def initialize(dry_run: false, out: $stdout, client: nil)
      @dry_run = dry_run
      @out = out
      @client = client
    end

    # ---- read-only operations: always execute, dry-run or not ----

    def ls_remote(dir, ref)
      out, = run!(%w[git] + ["-C", dir, "ls-remote", "origin", ref])
      out.split("\t").first.to_s.strip
    end

    def rev_parse(dir, ref = "HEAD")
      out, = run!(%w[git] + ["-C", dir, "rev-parse", ref])
      out.strip
    end

    # Resolves refs/tags/<tag> on origin to its COMMIT sha ("" if absent).
    # Queries the dereferenced ^{} ref too: an annotated tag's plain line is
    # the tag object's sha, and the peeled ^{} line is the commit it points
    # at — the peeled line wins when present (Promote compares a commit sha).
    def tag_sha(dir, tag)
      out, = run!(%w[git] + ["-C", dir, "ls-remote", "origin", "refs/tags/#{tag}", "refs/tags/#{tag}^{}"])
      lines = out.lines.map(&:strip).reject(&:empty?)
      peeled = lines.find { |line| line.end_with?("^{}") }
      chosen = peeled || lines.first
      chosen.to_s.split("\t").first.to_s.strip
    end

    # The highest-sorting local tag matching `pattern` ("" if none). Sorts by
    # `-v:refname` (semver) not `-creatordate`, since a hotfix tag for an
    # older line can be created after a newer release tag.
    def latest_tag(dir, pattern)
      out, = run!(["git", "-C", dir, "tag", "--list", pattern, "--sort=-v:refname"])
      out.lines.first.to_s.strip
    end

    # Whether `ancestor` is reachable from `descendant` in the local clone.
    # merge-base --is-ancestor exits non-zero for "no" AND for errors (e.g. a
    # sha the clone lacks) — either way the relationship isn't trustworthy, so
    # any failure is false.
    def ancestor?(dir, ancestor, descendant)
      _out, _err, status = run(["git", "-C", dir, "merge-base", "--is-ancestor", ancestor, descendant])
      status.success?
    end

    # Author emails (%ae) of the commits in `range` (e.g. "dev..release/2.2.0"),
    # one line per commit in git-log order. Empty range -> []. Read-only.
    # NB: lines(chomp: true), NOT split("\n") — split drops a *trailing* empty
    # field, so a sole empty-`%ae` commit ("\n") would collapse to [] and vanish;
    # lines keeps it as [""]. An empty/malformed author must survive so it counts
    # as a distinct (non-bot) author and forces a back-merge. Do NOT reject-empty.
    def commit_authors(dir, range)
      out, = run!(["git", "-C", dir, "log", "--format=%ae", range])
      out.lines(chomp: true)
    end

    # The origin remote URL of a local checkout (https or scp-like ssh). Read-only;
    # used to confirm a checkout belongs to the repo we think it does.
    def remote_url(dir)
      out, = run!(["git", "-C", dir, "remote", "get-url", "origin"])
      out.strip
    end

    def clone(url, dest, depth: nil, filter: nil)
      args = %w[git clone --quiet]
      args += ["--depth", depth.to_s] if depth
      args += ["--filter", filter] if filter
      args += [url, dest]
      run!(args)
      dest
    end

    RELEASES_URL = "github.com/xmtplabs/convos-releases.git"

    # The token-bearing convos-releases clone URL — one source of truth for
    # readers (Merge/Promote) and StateWriter. GH_TOKEN is read at call time
    # so dry-run/no-token paths that never clone don't require it.
    def releases_clone_url
      "https://x-access-token:#{ENV["GH_TOKEN"]}@#{RELEASES_URL}"
    end

    # Fresh depth-1 clone of convos-releases into a tmpdir, yielded and always
    # cleaned up. The read-only counterpart to StateWriter — every reader
    # re-clones to get whatever's CURRENT on main. Returns the block's value.
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
      run!(["git", "-C", dir, "checkout", "--quiet", ref])
    end

    # PRs matching repo/head/base/state, normalized to plain string-keyed
    # Hashes. merged_at is nil for an unmerged PR (open or closed-without-merge),
    # which Merge#find_pr uses to tell "closed merged" from "closed abandoned".
    def pr_list(repo:, head: nil, base: nil, state: "open")
      options = { state: state }
      options[:head] = "#{repo.split("/").first}:#{head}" if head
      options[:base] = base if base
      api! { client.pull_requests(repo, options) }
        .map do |pr|
          {
            "number" => pr[:number], "url" => pr[:html_url], "merged_at" => pr[:merged_at],
            "head-sha" => pr.dig(:head, :sha)
          }
        end
    end

    # Raw PR data (number, title, author.is_bot) for merged dev PRs since the
    # given ISO date, for Notes.format to render. author.is_bot is synthesized
    # from search_issues' `user` so Notes.format needn't know the API shape.
    def merged_prs_since(repo, since)
      query = "repo:#{repo} is:pr base:dev is:merged merged:>=#{since}"
      result = api! { client.search_issues(query, per_page: 100) }
      Array(result[:items]).map do |item|
        {
          "number" => item[:number],
          "title" => item[:title],
          "author" => { "is_bot" => item.dig(:user, :type) == "Bot" }
        }
      end
    end

    # The permission level ("admin"/"write"/"maintain"/"triage"/"read"/"none")
    # `login` has on `repo`. Read-only — Merge's gate needs the real answer
    # even under dry-run.
    def collaborator_permission(repo, login)
      api! { client.permission_level(repo, login) }[:permission]
    end

    # Whether `repo` has a GitHub Release tagged `tag`. Read-only — Promote#record
    # needs the real answer under dry-run. A 404 is `false`, not an error.
    # Bypasses api! deliberately: api! would rescue the NotFound we branch on,
    # so the 404-vs-real-error split runs on the raw Octokit hierarchy here.
    def release_exists?(repo, tag)
      client.release_for_tag(repo, tag)
      true
    rescue Octokit::NotFound
      false
    rescue Octokit::Error => e
      raise ApiError.new("release_for_tag(#{repo}, #{tag}): #{e.message}", cause: e)
    end

    # branch_exists?: whether refs/heads/<branch> currently exists on the
    # repo. Read-only; same raw-client + rescue-ordering shape as
    # release_exists? (api! would swallow the NotFound we branch on).
    def branch_exists?(repo, branch)
      client.branch(repo, branch)
      true
    rescue Octokit::NotFound
      false
    rescue Octokit::Error => e
      raise ApiError.new("branch(#{repo}, #{branch}): #{e.message}", cause: e)
    end

    # create_ref: creates refs/heads/<branch> at `sha` — used to restore a
    # branch that GitHub's delete-branch-on-merge removed when a later step
    # (the hotfix back-merge PR) still needs it as a PR head.
    def create_ref(repo, branch:, sha:)
      mutate!("create_ref #{repo} #{branch} @ #{sha}") do
        api! { client.create_ref(repo, "heads/#{branch}", sha) }
      end
    end

    # True if `path` has uncommitted changes. Read-only.
    def dirty?(dir, path)
      _out, _err, status = run(["git", "-C", dir, "diff", "--quiet", "--", path])
      !status.success?
    end

    # `git checkout -B branch sha` — creates/resets a local branch. Local-only
    # (no push); staged bump content is discarded under dry-run's gated commit.
    def checkout_branch(dir, branch, sha)
      run!(["git", "-C", dir, "checkout", "--quiet", "-B", branch, sha])
    end

    # `git reset --hard ref` — forcibly resets `dir`'s checkout to `ref`,
    # discarding any local commits/changes. Local-only (no push). Used to
    # recover from a failed persist push: the local checkout would otherwise
    # sit one commit ahead of origin, wedging the next run's
    # guard_synced_checkout until a human resets it.
    def reset_hard(dir, ref)
      run!(["git", "-C", dir, "reset", "--hard", ref])
    end

    # `git fetch origin <refspec>` — pulls `refspec`'s objects into `dir`'s
    # local object store (populating FETCH_HEAD) without touching the
    # checkout. Like reset_hard, this only ever reads objects into the local
    # clone, so it runs unconditionally rather than through mutate!. Used
    # before reset_hard to recover from a non-fast-forward push: the remote
    # sha ls_remote reports may not exist in this clone yet.
    def fetch(dir, refspec)
      run!(["git", "-C", dir, "fetch", "origin", refspec])
    end

    # ---- mutating operations: no-op (but logged) under dry-run ----

    def git_config_bot(dir)
      mutate!("git config user.name/email (#{dir})") do
        run!(["git", "-C", dir, "config", "user.name", BOT_AUTHOR_NAME])
        run!(["git", "-C", dir, "config", "user.email", BOT_AUTHOR_EMAIL])
      end
    end

    def add(dir, path)
      mutate!("git add #{path} (#{dir})") { run!(["git", "-C", dir, "add", path]) }
    end

    # `git commit [-a] -m message`. Returns true if a commit was made, false if
    # there was nothing to commit (no-change-ok, like the bash's `|| exit 0`).
    def commit(dir, message, all: false)
      mutate!("git commit #{message.inspect} (#{dir})", default: true) do
        args = ["git", "-C", dir, "commit"]
        args << "-a" if all
        args += ["-m", message]
        out, err, status = run(args)
        next true if status.success?
        # "nothing to commit" is success (no-change-ok); anything else is a
        # real failure.
        next false if "#{out}#{err}".match?(/nothing to commit/i)

        raise CommandError.new(args, stdout: out, stderr: err, status: status)
      end
    end

    # Returns true on success, false on a rejected push (e.g. non-fast-forward
    # from a lost race) — the seam's one boolean mutation; everything else
    # raises CommandError. Callers MUST check the return so they can tell a
    # rejected push from git blowing up.
    def push(dir, refspec, force: false)
      mutate!("git push origin #{refspec} (#{dir})", default: true) do
        args = ["git", "-C", dir, "push"]
        args << "-f" if force
        args += ["origin", refspec]
        _out, _err, status = run(args)
        status.success?
      end
    end

    def set_remote_url(dir, url)
      mutate!("git remote set-url origin (#{dir})") do
        run!(["git", "-C", dir, "remote", "set-url", "origin", url])
      end
    end

    # Return value is discarded — callers create-and-forget, and pr_merge_auto
    # resolves the PR itself rather than needing this return's node_id.
    def pr_create(repo:, base:, head:, title:, body:)
      mutate!("create PR #{repo} #{head}->#{base}: #{title.inspect}") do
        api! { client.create_pull_request(repo, base, head, title, body) }
        nil
      end
    end

    # create_release: mutation-gated. `name` and `body` mirror Octokit's
    # create_release options.
    def create_release(repo, tag:, name:, body:)
      mutate!("create release #{repo}@#{tag}") do
        api! { client.create_release(repo, tag, name: name, body: body) }
        nil
      end
    end

    # pr_comment: post an issue/PR comment. Mutation-gated like pr_create.
    def pr_comment(repo, number, body)
      mutate!("comment on #{repo}##{number}") do
        api! { client.add_comment(repo, number, body) }
        nil
      end
    end

    # Merge PR `number` via merge_method. Mutation-gated; any Octokit failure
    # surfaces as ApiError. expected_head_sha (when given) becomes the API's
    # `sha` guard — GitHub rejects the merge if the tip moved after lookup.
    def pr_merge(repo, number, merge_method: "merge", expected_head_sha: nil)
      mutate!("merge #{repo}##{number} (#{merge_method})", default: true) do
        options = { merge_method: merge_method }
        options[:sha] = expected_head_sha if expected_head_sha
        api! { client.merge_pull_request(repo, number, "", options) }
        true
      end
    end

    # Tried in order by pr_merge_auto: a repo that disallows a method makes
    # GraphQL reject it ("not allowed") without falling back, so walk the list.
    MERGE_METHODS = %w[SQUASH MERGE REBASE].freeze

    # Enable GitHub's native auto-merge (GraphQL-only, needs the PR node id).
    # head_or_number may be a branch name or a PR number — resolve to the PR
    # object either way. Tries MERGE_METHODS in order.
    def pr_merge_auto(repo:, head_or_number:)
      mutate!("enable auto-merge #{repo}##{head_or_number}", default: true) do
        pr = if head_or_number.is_a?(Integer) || head_or_number.to_s.match?(/\A\d+\z/)
          api! { client.pull_request(repo, head_or_number.to_i) }
        else
          owner = repo.split("/").first
          api! { client.pull_requests(repo, head: "#{owner}:#{head_or_number}", state: "open") }.first
        end
        unless pr
          @out.puts "train: warning: auto-merge: PR #{repo}##{head_or_number} not found"
          next false
        end

        try_merge_methods(repo: repo, head_or_number: head_or_number, node_id: pr[:node_id],
                          number: pr[:number], head_sha: pr.dig(:head, :sha))
      end
    end

    private

    # Tries each MERGE_METHOD in turn: a /not allowed/i GraphQL error advances
    # to the next, any other error is final. Returns true on the first
    # accepted method, false (warning) if all are rejected.
    def try_merge_methods(repo:, head_or_number:, node_id:, number:, head_sha: nil)
      attempted = []
      last_message = nil
      MERGE_METHODS.each do |method|
        attempted << method
        errors = attempt_auto_merge(node_id: node_id, method: method)
        return true if errors.nil?

        last_message = errors.map { |e| e[:message] }.join("; ")
        next if last_message.match?(/not allowed/i)

        # GitHub refuses to ARM auto-merge on an already-mergeable PR
        # ("clean status") — merge it directly, pinned to the tip we looked
        # up so a commit landing in between is rejected, not merged blind.
        if last_message.match?(/clean status/i)
          options = { merge_method: method.downcase }
          options[:sha] = head_sha if head_sha
          api! { client.merge_pull_request(repo, number, "", options) }
          @out.puts "#{repo}##{number}: already mergeable — merged directly (#{method})"
          return true
        end

        @out.puts "train: warning: auto-merge failed for #{repo}##{head_or_number} (#{method}): #{last_message}"
        return false
      rescue ApiError => e
        @out.puts "train: warning: auto-merge failed for #{repo}##{head_or_number} (#{method}): #{e.message}"
        return false
      end

      @out.puts "train: warning: auto-merge failed for #{repo}##{head_or_number} (tried #{attempted.join(", ")}): #{last_message}"
      false
    end

    # Posts the GraphQL mutation for one merge method. Returns nil on success,
    # or the errors array on failure (empty errors normalized to nil).
    def attempt_auto_merge(node_id:, method:)
      mutation = {
        query: <<~GQL,
          mutation($pullRequestId: ID!) {
            enablePullRequestAutoMerge(input: { pullRequestId: $pullRequestId, mergeMethod: #{method} }) {
              pullRequest { id }
            }
          }
        GQL
        variables: { pullRequestId: node_id }
      }.to_json
      response = api! { client.post "/graphql", mutation }
      errors = response[:errors]
      errors && !errors.empty? ? errors : nil
    end

    def client
      require "octokit"
      @client ||= Octokit::Client.new(access_token: ENV.fetch("GH_TOKEN"), auto_paginate: true)
    end

    # Central seam for API calls — normalizes any Octokit failure into ApiError.
    def api!
      yield
    rescue Octokit::Error => e
      raise ApiError.new("GitHub API error: #{e.message}", cause: e)
    end

    # Dry-run gate: logs the action and returns `default` without running (nor
    # instantiating a client — dry-run must work with no GH_TOKEN). Live,
    # yields the block.
    def mutate!(description, default: nil)
      if @dry_run
        @out.puts "[dry-run] #{description}"
        return default
      end
      yield
    end

    def run(args)
      stdout, stderr, status = Open3.capture3(*args)
      [stdout, stderr, status]
    end

    def run!(args)
      stdout, stderr, status = run(args)
      raise CommandError.new(args, stdout: stdout, stderr: stderr, status: status) unless status.success?

      [stdout, stderr]
    end
  end
end
