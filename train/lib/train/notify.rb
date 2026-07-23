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
    RELEASES_URL = "https://github.com/xmtplabs/convos-releases"
    DASHBOARD_URL = "https://releases.convos.fun"
    SLACK_API = "https://slack.com/api/chat.postMessage"

    def initialize(bot_token: ENV["SLACK_BOT_TOKEN"], channel: ENV["SLACK_CHANNEL_APP"],
                   out: $stdout, err: $stderr)
      @bot_token = bot_token
      @channel = channel
      @out = out
      @err = err
    end

    # Returns {channel:, ts:} on success, nil on skip or failure.
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

    # Slack signals errors as 200 + {"ok": false}; both layers must pass.
    def post_message(text)
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
      unless response.is_a?(Net::HTTPSuccess) && body["ok"]
        @err.puts "train: warning: Slack notification failed: HTTP #{response.code} #{body["error"]}".rstrip
        return nil
      end

      @out.puts "notify: Slack announcement posted (ts #{body["ts"]})"
      { channel: body["channel"], ts: body["ts"] }
    end
  end
end
