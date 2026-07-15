# frozen_string_literal: true

require "open3"
require "json"

module Train
  # ALL git subprocess calls AND GitHub API calls live here. Centralizing
  # dry-run enforcement here (rather than sprinkling `unless dry_run`
  # through cut.rb) means a missed check can't silently mutate state —
  # every mutating method starts with the same guard, and any new mutating
  # method just has to call through mutate!/run! (or api!) to inherit it.
  #
  # Git plumbing (clone/checkout/rev-parse/commit/push/ls-remote/etc) stays
  # on `git` subprocesses via Open3 — no GitHub API involved. GitHub API
  # calls (PR list/create/merge) go through Octokit instead of shelling out
  # to the `gh` CLI.
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

      # redact: strips userinfo (e.g. x-access-token:<TOKEN>) out of any URL
      # embedded in the text, so failed clone/push commands never leak the
      # token into logs via this error's message — neither from argv nor
      # from git's own error output.
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

    # tag_sha: resolves refs/tags/<tag> on origin — "" if the tag doesn't
    # exist. Read-only (ls-remote), so it always executes, dry-run or not.
    #
    # Queries BOTH refs/tags/<tag> and its dereferenced form
    # refs/tags/<tag>^{} in one ls-remote call: for an ANNOTATED tag (e.g.
    # one created through GitHub's release UI, as opposed to `git tag` /
    # `git push origin <sha>:refs/tags/<tag>`, which make lightweight tags),
    # ls-remote returns TWO lines — the tag OBJECT's own sha, and a second
    # "^{}" line with the COMMIT sha it points at. Promote#ensure_tag
    # compares this against a commit sha (merge_sha), so the peeled ^{}
    # line must win whenever present; only a lightweight tag (single line,
    # no ^{} line) falls back to the plain sha.
    def tag_sha(dir, tag)
      out, = run!(%w[git] + ["-C", dir, "ls-remote", "origin", "refs/tags/#{tag}", "refs/tags/#{tag}^{}"])
      lines = out.lines.map(&:strip).reject(&:empty?)
      peeled = lines.find { |line| line.end_with?("^{}") }
      chosen = peeled || lines.first
      chosen.to_s.split("\t").first.to_s.strip
    end

    # latest_tag: the highest-sorting local tag matching `pattern` (e.g.
    # "v*"), or "" if none exist. Sorts by `-v:refname` — a version-aware
    # descending sort — rather than `-creatordate`, since creation order can
    # disagree with semver order (e.g. a hotfix tag for an older line
    # created after a newer release tag). Requires a clone with tag history
    # (Hotfix clones blob:none, which still fetches all tags). Read-only, so
    # it always executes, dry-run or not.
    def latest_tag(dir, pattern)
      out, = run!(["git", "-C", dir, "tag", "--list", pattern, "--sort=-v:refname"])
      out.lines.first.to_s.strip
    end

    # ancestor?: whether `ancestor` is reachable from `descendant` in the
    # local clone. merge-base --is-ancestor exits 1 for "no" and other
    # non-zero for errors (e.g. a sha the clone doesn't have) — both mean
    # the caller can't trust the relationship, so any failure is false.
    # Read-only, so it always executes, dry-run or not.
    def ancestor?(dir, ancestor, descendant)
      _out, _err, status = run(["git", "-C", dir, "merge-base", "--is-ancestor", ancestor, descendant])
      status.success?
    end

    def clone(url, dest, depth: nil, filter: nil)
      args = %w[git clone --quiet]
      args += ["--depth", depth.to_s] if depth
      args += ["--filter", filter] if filter
      args += [url, dest]
      run!(args)
      dest
    end

    def checkout(dir, ref)
      run!(["git", "-C", dir, "checkout", "--quiet", ref])
    end

    # pr_list: PRs matching repo/head/base/state, normalized to plain
    # string-keyed Hashes (number, url, merged_at) — same shape callers got
    # from `gh pr list --json number,url,mergedAt`, regardless of Octokit's
    # Sawyer::Resource internals. merged_at is nil for an unmerged PR (open
    # or closed-without-merging); Merge#find_pr uses it to tell "closed,
    # merged" from "closed, abandoned" when scanning state: "all".
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

    # merged_prs_since: raw PR data (number, title, author.is_bot) for
    # merged dev PRs since the given ISO date. Notes.format is the pure
    # formatter over this data — kept separate so tests can feed it
    # fixture data without a real API call. author.is_bot is synthesized
    # here (search_issues returns `user`, not gh CLI's `author`) so
    # Notes.format doesn't need to know the underlying API changed.
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

    # collaborator_permission: the permission level ("admin", "write",
    # "maintain", "triage", "read"/"none") `login` has on `repo`, straight
    # from Octokit's permission_level endpoint. Read-only, so it always
    # executes (dry-run or not) — Merge's permission gate needs the real
    # answer even under dry-run.
    def collaborator_permission(repo, login)
      api! { client.permission_level(repo, login) }[:permission]
    end

    # release_exists?: true/false for whether `repo` already has a GitHub
    # Release tagged `tag`. Read-only (always executes, dry-run or not) —
    # Promote#record needs the real answer under dry-run too, to print an
    # accurate "would create" vs "already exists" line. A 404 from Octokit
    # means "no release for this tag" and is treated as `false` rather than
    # an ApiError; any other Octokit failure still raises ApiError.
    #
    # Deliberately does NOT go through api!: api! rescues Octokit::Error —
    # NotFound's ancestor — inside the wrapped call and re-raises ApiError,
    # so a `rescue Octokit::NotFound` around api! would be dead code (the
    # NotFound never escapes api!) and every first-time release creation
    # would hard-fail. The 404-vs-real-error split has to happen on the raw
    # Octokit exception hierarchy, with the ApiError normalization inlined
    # for the non-404 case.
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

    # dirty?: true if `path` (relative to dir) has uncommitted changes.
    # Mirrors `git diff --quiet -- "$mdir"` — read-only, so it always
    # executes even under dry-run (dry-run never reaches this point since
    # cut.rb returns early, but it's not a mutation regardless).
    def dirty?(dir, path)
      _out, _err, status = run(["git", "-C", dir, "diff", "--quiet", "--", path])
      !status.success?
    end

    # checkout_branch: `git checkout -B branch sha` — creates or resets a
    # local branch to sha. Read/local-only (no push), so it always
    # executes; the bump content it stages is discarded under dry-run
    # because the subsequent commit/push are gated.
    def checkout_branch(dir, branch, sha)
      run!(["git", "-C", dir, "checkout", "--quiet", "-B", branch, sha])
    end

    # ---- mutating operations: no-op (but logged) under dry-run ----

    def git_config_bot(dir)
      mutate!("git config user.name/email (#{dir})") do
        run!(["git", "-C", dir, "config", "user.name", "convos-conductor"])
        run!(["git", "-C", dir, "config", "user.email", "convos-conductor[bot]@users.noreply.github.com"])
      end
    end

    def add(dir, path)
      mutate!("git add #{path} (#{dir})") { run!(["git", "-C", dir, "add", path]) }
    end

    # commit: `git commit [-a] -m message`. Returns true if a commit was
    # made, false if there was nothing to commit (mirrors the bash's
    # `|| exit 0` no-change-ok semantics used by manifest/status commits).
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

    # push: returns boolean (true on success, false on a rejected/failed
    # push) — the seam's ONE boolean mutation; everything else raises
    # CommandError. Callers MUST check this return value; a `false` here
    # (e.g. non-fast-forward) is a real, expected failure mode (lost a race
    # to another writer, or a branch already exists at a different sha) —
    # not a CommandError, precisely so callers can distinguish "rejected
    # push" from "git itself blew up" and react accordingly (retry, fail
    # loud, or skip a downstream step) instead of it being conflated with
    # every other subprocess error.
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

    # pr_create: return value is intentionally discarded (nil) — both
    # call sites (cut.rb) create-and-forget, and pr_merge_auto resolves the
    # PR itself (by branch name or number) rather than needing this
    # return's node_id.
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

    # pr_merge: merge PR `number` on `repo` via the given merge_method
    # ("merge", "squash", "rebase"). Mutation-gated. Any Octokit failure
    # (already merged, checks failing, conflicts, ...) surfaces as
    # ApiError — Merge#run turns that into a per-repo Failure rather than
    # letting it propagate and abort the other repo's attempt.
    def pr_merge(repo, number, merge_method: "merge")
      mutate!("merge #{repo}##{number} (#{merge_method})", default: true) do
        api! { client.merge_pull_request(repo, number, "", merge_method: merge_method) }
        true
      end
    end

    # MERGE_METHODS: tried in order by pr_merge_auto. Some repos (e.g.
    # convos-client) disallow squash merges, in which case GitHub's GraphQL
    # API rejects mergeMethod:SQUASH with a "not allowed" error rather than
    # falling back itself — so pr_merge_auto walks this list until one
    # method is accepted.
    MERGE_METHODS = %w[SQUASH MERGE REBASE].freeze

    # pr_merge_auto: enable GitHub's native auto-merge on a PR. The REST API
    # has no endpoint for this — it's GraphQL-only
    # (enablePullRequestAutoMerge), which needs the PR's GraphQL node id.
    # head_or_number may be a branch name (freshly created PR) or a PR
    # number (re-arming on an existing open PR) — resolve to the PR object
    # either way to get node_id. Tries MERGE_METHODS in order: a "not
    # allowed" GraphQL error (the repo forbids that merge method) advances
    # to the next method; any other error is treated as final (current
    # warn+false behavior).
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

        try_merge_methods(repo: repo, head_or_number: head_or_number, node_id: pr[:node_id])
      end
    end

    private

    # try_merge_methods: attempts enablePullRequestAutoMerge with each of
    # MERGE_METHODS in turn. A GraphQL error matching /not allowed/i (the
    # repo forbids that merge method — e.g. squash disabled) tries the next
    # method; any other error is final. Returns true on the first accepted
    # method, false (with a warning naming every attempted method) if all
    # are rejected.
    def try_merge_methods(repo:, head_or_number:, node_id:)
      attempted = []
      last_message = nil
      MERGE_METHODS.each do |method|
        attempted << method
        errors = attempt_auto_merge(node_id: node_id, method: method)
        return true if errors.nil?

        last_message = errors.map { |e| e[:message] }.join("; ")
        next if last_message.match?(/not allowed/i)

        @out.puts "train: warning: auto-merge failed for #{repo}##{head_or_number} (#{method}): #{last_message}"
        return false
      rescue ApiError => e
        @out.puts "train: warning: auto-merge failed for #{repo}##{head_or_number} (#{method}): #{e.message}"
        return false
      end

      @out.puts "train: warning: auto-merge failed for #{repo}##{head_or_number} (tried #{attempted.join(", ")}): #{last_message}"
      false
    end

    # attempt_auto_merge: posts the GraphQL mutation for one merge method.
    # Returns nil on success, or the GraphQL errors array on failure (empty
    # response[:errors] is normalized to nil so callers can `return true if
    # errors.nil?`).
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

    # api!: central seam for GitHub API calls — runs the block and
    # normalizes any Octokit failure into ApiError with a clear message.
    # octokit itself is lazily required by `client` (so dry-run / no-token
    # paths never load it).
    def api!
      yield
    rescue Octokit::Error => e
      raise ApiError.new("GitHub API error: #{e.message}", cause: e)
    end

    # mutate!: dry-run gate. Under dry-run, logs the intended action and
    # returns `default` without running anything (including without
    # instantiating an Octokit client — dry-run must work with no
    # GH_TOKEN set). Live, yields to the block and returns its result.
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
