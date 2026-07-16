# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Train
  # Posts a cut announcement to Slack (incoming webhook, SLACK_WEBHOOK_URL).
  # Best-effort by contract: no webhook means a printed note, and any HTTP
  # failure warns — a Slack outage must never fail a completed cut.
  class Notify
    RELEASES_URL = "https://github.com/xmtplabs/convos-releases"

    def initialize(webhook_url: ENV["SLACK_WEBHOOK_URL"], out: $stdout, err: $stderr)
      @webhook_url = webhook_url
      @out = out
      @err = err
    end

    def post_cut(version:, kind:)
      if @webhook_url.to_s.empty?
        @out.puts "notify: SLACK_WEBHOOK_URL not set — skipping Slack announcement"
        return
      end

      post(cut_text(version: version, kind: kind))
    rescue StandardError => e
      @err.puts "train: warning: Slack notification failed: #{e.class}: #{e.message}"
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
        • <#{RELEASES_URL}/blob/main/RUNBOOK.md|Runbook>
        When QA passes, comment `@convos-conductor merge` on a release PR.
      TEXT
    end

    private

    def pr_link(repo, kind, version)
      "https://github.com/xmtplabs/#{repo}/pulls?q=is%3Apr+head%3A#{kind}%2F#{version}"
    end

    def post(text)
      uri = URI(@webhook_url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                     open_timeout: 5, read_timeout: 10) do |http|
        request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
        request.body = JSON.generate({ text: text })
        http.request(request)
      end

      unless response.is_a?(Net::HTTPSuccess)
        @err.puts "train: warning: Slack notification failed: HTTP #{response.code}"
        return
      end

      @out.puts "notify: Slack announcement posted"
    end
  end
end
