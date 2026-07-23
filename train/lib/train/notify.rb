# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Train
  # Posts the cut announcement via Slack chat.postMessage (bot token) and
  # returns the {channel:, ts:} thread anchor so ConvosOS can reply in-thread.
  # Best-effort by contract: missing config prints a note, any failure warns —
  # a Slack outage must never fail a completed cut.
  class Notify
    # Raised only by announce() (the fail-loud manual path); post_cut() stays
    # best-effort and never raises.
    class Error < StandardError; end

    RELEASES_URL = "https://github.com/xmtplabs/convos-releases"
    DASHBOARD_URL = "https://releases.convos.fun"
    SLACK_API = "https://slack.com/api/chat.postMessage"

    # Turn the two Slack errors we've actually hit into fixes, not jargon.
    # Anything else falls through to the raw code.
    ERROR_HINTS = {
      "missing_scope" => "bot token is missing the chat:write scope — add it, then " \
                         "REINSTALL the app (new token) and update SLACK_BOT_TOKEN",
      "not_in_channel" => "bot is not a member of the channel — `/invite` it there, or " \
                          "grant chat:write.public to post without joining",
      "channel_not_found" => "channel id is wrong or the bot cannot see it — check SLACK_CHANNEL_APP",
      "invalid_auth" => "SLACK_BOT_TOKEN is invalid or revoked",
      "not_authed" => "SLACK_BOT_TOKEN is empty or not sent"
    }.freeze

    def initialize(bot_token: ENV["SLACK_BOT_TOKEN"], channel: ENV["SLACK_CHANNEL_APP"],
                   out: $stdout, err: $stderr)
      @bot_token = bot_token
      @channel = channel
      @out = out
      @err = err
    end

    # Best-effort (cut/hotfix path): {channel:, ts:} on success, nil on skip or
    # any failure — a Slack outage must never fail a completed cut.
    def post_cut(version:, kind:)
      if @bot_token.to_s.empty? || @channel.to_s.empty?
        @out.puts "notify: SLACK_BOT_TOKEN/SLACK_CHANNEL_APP not set — skipping Slack announcement"
        return nil
      end

      post_message(cut_text(version: version, kind: kind))
    rescue StandardError => e
      @err.puts "train: warning: Slack notification failed: #{e.class}: #{e.message}"
      nil
    end

    # Fail-loud (manual `train notify` path): returns {channel:, ts:} or raises
    # Notify::Error with an actionable hint. The user asked to send it, so a
    # silent nil would be wrong here.
    def announce(version:, kind:)
      if @bot_token.to_s.empty? || @channel.to_s.empty?
        raise Error, "SLACK_BOT_TOKEN/SLACK_CHANNEL_APP not set"
      end

      result = deliver(cut_text(version: version, kind: kind))
      return { channel: result[:channel], ts: result[:ts] } if result[:ok]

      hint = ERROR_HINTS[result[:error]]
      detail = hint ? "#{result[:error]} — #{hint}" : result[:error]
      raise Error, "Slack post to #{@channel} failed (HTTP #{result[:code]}): #{detail}".rstrip
    end

    # Public and pure so the exact message is unit-testable. PR links are
    # head-branch search URLs — stable without knowing PR numbers.
    def cut_text(version:, kind:)
      ios_pr = pr_link("convos-ios", kind, version)
      android_pr = pr_link("convos-client", kind, version)

      <<~TEXT.strip
        🚂 *#{kind} #{version} cut* — release branches are open; every push uploads an RC.
        • Release PRs: <#{ios_pr}|iOS> · <#{android_pr}|Android>
        • <#{RELEASES_URL}/tree/main/releases/#{version}|Release notes #{version}> — pencil-edit before merging
        • <#{RELEASES_URL}/blob/main/RUNBOOK.md|Runbook> · <#{DASHBOARD_URL}|Release dashboard>
        When QA passes, comment `@convos-conductor merge` on a release PR — or use the dashboard.
      TEXT
    end

    private

    def pr_link(repo, kind, version)
      "https://github.com/xmtplabs/#{repo}/pulls?q=is%3Apr+head%3A#{kind}%2F#{version}"
    end

    # Best-effort wrapper over deliver: warn+nil on failure, anchor on success.
    def post_message(text)
      result = deliver(text)
      unless result[:ok]
        @err.puts "train: warning: Slack notification failed: HTTP #{result[:code]} #{result[:error]}".rstrip
        return nil
      end

      @out.puts "notify: Slack announcement posted (ts #{result[:ts]})"
      { channel: result[:channel], ts: result[:ts] }
    end

    # deliver: the one place that talks to Slack. Returns a plain result hash
    # so callers choose how to react (warn vs raise). Slack signals errors as
    # HTTP 200 + {"ok": false}; both layers must pass for :ok.
    def deliver(text)
      uri = URI(SLACK_API)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                                     open_timeout: 5, read_timeout: 10) do |http|
        request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json; charset=utf-8",
                                           "Authorization" => "Bearer #{@bot_token}")
        request.body = JSON.generate({ channel: @channel, text: text })
        http.request(request)
      end

      body = begin
        JSON.parse(response.body)
      rescue JSON::ParserError
        {}
      end
      ok = response.is_a?(Net::HTTPSuccess) && body["ok"]
      { ok: ok, code: response.code, error: body["error"],
        channel: body["channel"], ts: body["ts"] }
    end
  end
end
