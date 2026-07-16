# frozen_string_literal: true

require_relative "test_helper"
require "train/notify"

class NotifyTest < Minitest::Test
  def setup
    @out = StringIO.new
    @err = StringIO.new
  end

  def test_cut_text_contains_version_links_and_merge_hint
    text = Train::Notify.new(webhook_url: nil, out: @out, err: @err).cut_text(version: "2.1.0", kind: "release")

    assert_match(/release 2\.1\.0 cut/, text)
    assert_includes text, "https://github.com/xmtplabs/convos-releases/tree/main/releases/2.1.0"
    assert_includes text, "https://github.com/xmtplabs/convos-releases/blob/main/RUNBOOK.md"
    assert_includes text, "@convos-conductor merge"
    # PR links: head-branch search URLs, kind-prefixed
    assert_includes text, "https://github.com/xmtplabs/convos-ios/pulls?q=is%3Apr+head%3Arelease%2F2.1.0"
    assert_includes text, "https://github.com/xmtplabs/convos-client/pulls?q=is%3Apr+head%3Arelease%2F2.1.0"
  end

  def test_cut_text_pr_links_use_the_hotfix_prefix_for_hotfixes
    text = Train::Notify.new(webhook_url: nil, out: @out, err: @err).cut_text(version: "2.1.1", kind: "hotfix")

    assert_includes text, "head%3Ahotfix%2F2.1.1"
  end

  def test_post_cut_skips_with_a_note_when_webhook_unset
    notify = Train::Notify.new(webhook_url: nil, out: @out, err: @err)

    notify.post_cut(version: "2.1.0", kind: "release")

    assert_match(/SLACK_WEBHOOK_URL not set/, @out.string)
    assert_empty @err.string
  end

  def test_post_cut_warns_instead_of_raising_on_failure
    notify = Train::Notify.new(webhook_url: "https://hooks.slack.example/x", out: @out, err: @err)
    notify.define_singleton_method(:post) { |_text| raise Errno::ECONNREFUSED }

    notify.post_cut(version: "2.1.0", kind: "hotfix")

    assert_match(/warning: Slack notification failed/, @err.string)
  end
end
