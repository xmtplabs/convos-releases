# frozen_string_literal: true

require_relative "test_helper"
require "train/notify"

class NotifyTest < Minitest::Test
  def setup
    @out = StringIO.new
    @err = StringIO.new
  end

  def notify(bot_token: "xoxb-test", channel: "C0APP")
    Train::Notify.new(bot_token: bot_token, channel: channel, out: @out, err: @err)
  end

  def test_cut_text_contains_version_links_and_merge_hint
    text = notify.cut_text(version: "2.1.0", kind: "release")

    assert_match(/release 2\.1\.0 cut/, text)
    assert_includes text, "https://github.com/xmtplabs/convos-releases/tree/main/releases/2.1.0"
    assert_includes text, "https://github.com/xmtplabs/convos-releases/blob/main/RUNBOOK.md"
    assert_includes text, "https://releases.convos.fun"
    assert_includes text, "@convos-conductor merge"
    assert_includes text, "https://github.com/xmtplabs/convos-ios/pulls?q=is%3Apr+head%3Arelease%2F2.1.0"
    assert_includes text, "https://github.com/xmtplabs/convos-client/pulls?q=is%3Apr+head%3Arelease%2F2.1.0"
  end

  def test_cut_text_pr_links_use_the_hotfix_prefix_for_hotfixes
    text = notify.cut_text(version: "2.1.1", kind: "hotfix")

    assert_includes text, "head%3Ahotfix%2F2.1.1"
  end

  def test_post_cut_skips_with_a_note_when_token_or_channel_unset
    assert_nil notify(bot_token: nil).post_cut(version: "2.1.0", kind: "release")
    assert_match(/SLACK_BOT_TOKEN\/SLACK_CHANNEL_APP not set/, @out.string)

    assert_nil notify(channel: nil).post_cut(version: "2.1.0", kind: "release")
    assert_empty @err.string
  end

  def test_post_cut_returns_the_thread_anchor_from_post_message
    n = notify
    n.define_singleton_method(:post_message) { |_text| { channel: "C0APP", ts: "1700000000.000100" } }

    result = n.post_cut(version: "2.1.0", kind: "release")

    assert_equal({ channel: "C0APP", ts: "1700000000.000100" }, result)
  end

  def test_post_cut_warns_and_returns_nil_on_failure
    n = notify
    n.define_singleton_method(:post_message) { |_text| raise Errno::ECONNREFUSED }

    assert_nil n.post_cut(version: "2.1.0", kind: "hotfix")
    assert_match(/warning: Slack notification failed/, @err.string)
  end

  # ---- announce: the fail-loud manual path ----

  def stub_deliver(n, result)
    n.define_singleton_method(:deliver) { |_text| result }
  end

  def test_announce_returns_anchor_on_success
    n = notify
    stub_deliver(n, { ok: true, code: "200", error: nil, channel: "C0APP", ts: "1700000000.000100" })

    assert_equal({ channel: "C0APP", ts: "1700000000.000100" },
                 n.announce(version: "2.2.0", kind: "release"))
  end

  def test_announce_raises_with_actionable_hint_on_missing_scope
    n = notify
    stub_deliver(n, { ok: false, code: "200", error: "missing_scope", channel: nil, ts: nil })

    error = assert_raises(Train::Notify::Error) { n.announce(version: "2.2.0", kind: "release") }
    assert_match(/missing_scope/, error.message)
    assert_match(/chat:write/, error.message)
    assert_match(/REINSTALL/, error.message)
  end

  def test_announce_raises_with_actionable_hint_on_not_in_channel
    n = notify
    stub_deliver(n, { ok: false, code: "200", error: "not_in_channel", channel: nil, ts: nil })

    error = assert_raises(Train::Notify::Error) { n.announce(version: "2.2.0", kind: "release") }
    assert_match(/not_in_channel/, error.message)
    assert_match(/invite/, error.message)
    assert_match(/C0APP/, error.message)
  end

  def test_announce_passes_through_unknown_slack_errors
    n = notify
    stub_deliver(n, { ok: false, code: "200", error: "ratelimited", channel: nil, ts: nil })

    error = assert_raises(Train::Notify::Error) { n.announce(version: "2.2.0", kind: "release") }
    assert_match(/ratelimited/, error.message)
  end

  def test_announce_raises_when_token_or_channel_unset
    assert_raises(Train::Notify::Error) do
      notify(bot_token: nil).announce(version: "2.2.0", kind: "release")
    end
    assert_raises(Train::Notify::Error) do
      notify(channel: nil).announce(version: "2.2.0", kind: "release")
    end
  end
end
