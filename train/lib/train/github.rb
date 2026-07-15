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

    def tags(dir, pattern)
      out, = run!(["git", "-C", dir, "tag", "--list", pattern, "--sort=-creatordate"])
      out.split("\n").map(&:strip).reject(&:empty?)
    end

    def commit_date(dir, ref)
      out, = run!(["git", "-C", dir, "log", "-1", "--format=%cs", ref])
      out.strip
    end

    # pr_list: PRs matching repo/head/base/state, normalized to plain
    # string-keyed Hashes (number, url) — same shape callers got from `gh
    # pr list --json number,url`, regardless of Octokit's Sawyer::Resource
    # internals.
    def pr_list(repo:, head: nil, base: nil, state: "open")
      options = { state: state }
      options[:head] = "#{repo.split("/").first}:#{head}" if head
      options[:base] = base if base
      api! { client.pull_requests(repo, options) }
        .map { |pr| { "number" => pr[:number], "url" => pr[:html_url] } }
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

    # pr_merge_auto: enable GitHub's native auto-merge (squash) on a PR.
    # The REST API has no endpoint for this — it's GraphQL-only
    # (enablePullRequestAutoMerge), which needs the PR's GraphQL node id.
    # head_or_number may be a branch name (freshly created PR) or a PR
    # number (re-arming on an existing open PR) — resolve to the PR object
    # either way to get node_id.
    def pr_merge_auto(repo:, head_or_number:)
      mutate!("enable auto-merge (squash) #{repo}##{head_or_number}", default: true) do
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

        begin
          mutation = {
            query: <<~GQL,
              mutation($pullRequestId: ID!) {
                enablePullRequestAutoMerge(input: { pullRequestId: $pullRequestId, mergeMethod: SQUASH }) {
                  pullRequest { id }
                }
              }
            GQL
            variables: { pullRequestId: pr[:node_id] }
          }.to_json
          response = api! { client.post "/graphql", mutation }
          errors = response[:errors]
          if errors && !errors.empty?
            @out.puts "train: warning: auto-merge failed for #{repo}##{head_or_number}: #{errors.map { |e| e[:message] }.join("; ")}"
            false
          else
            true
          end
        rescue ApiError => e
          @out.puts "train: warning: auto-merge failed for #{repo}##{head_or_number}: #{e.message}"
          false
        end
      end
    end

    private

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
