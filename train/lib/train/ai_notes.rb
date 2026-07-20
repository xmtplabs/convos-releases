# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Train
  # Asks ConvosOS (os-agent /hooks/run) to draft release notes as a PR.
  # Authenticated with a Cloudflare Access service token; the prompt lives
  # server-side, so this only names an automation and a version. Best-effort:
  # missing config prints a note, any failure warns — never fails a cut.
  class AiNotes
    def initialize(hook_url: ENV["OS_HOOK_URL"], client_id: ENV["OS_HOOK_CLIENT_ID"],
                   client_secret: ENV["OS_HOOK_CLIENT_SECRET"], out: $stdout, err: $stderr)
      @hook_url = hook_url
      @client_id = client_id
      @client_secret = client_secret
      @out = out
      @err = err
    end

    # slack: the {channel:, ts:} anchor from Notify#post_cut (or nil).
    def request(version:, slack: nil)
      if [@hook_url, @client_id, @client_secret].any? { |v| v.to_s.empty? }
        @out.puts "ai-notes: OS_HOOK_URL/OS_HOOK_CLIENT_ID/OS_HOOK_CLIENT_SECRET not set — skipping AI draft request"
        return false
      end

      params = { version: version }
      params[:slack] = { channel: slack[:channel], thread_ts: slack[:ts] } if slack
      post_json({ automation: "release-notes", params: params })
    rescue StandardError => e
      @err.puts "train: warning: AI notes request failed: #{e.class}: #{e.message}"
      false
    end

    private

    def post_json(body)
      uri = URI(@hook_url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                     open_timeout: 5, read_timeout: 10) do |http|
        request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json",
                                           "CF-Access-Client-Id" => @client_id,
                                           "CF-Access-Client-Secret" => @client_secret)
        request.body = JSON.generate(body)
        http.request(request)
      end

      unless response.is_a?(Net::HTTPSuccess)
        @err.puts "train: warning: AI notes request failed: HTTP #{response.code}"
        return false
      end

      @out.puts "ai-notes: draft requested from ConvosOS"
      true
    end
  end
end
