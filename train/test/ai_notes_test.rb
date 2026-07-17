# frozen_string_literal: true

require_relative "test_helper"
require "train/ai_notes"

class AiNotesTest < Minitest::Test
  def setup
    @out = StringIO.new
    @err = StringIO.new
  end

  def ai_notes(hook_url: "https://os.example/hooks/run", client_id: "id", client_secret: "secret")
    Train::AiNotes.new(hook_url: hook_url, client_id: client_id, client_secret: client_secret,
                       out: @out, err: @err)
  end

  def test_request_skips_with_a_note_when_config_unset
    refute ai_notes(hook_url: nil).request(version: "2.1.0")
    assert_match(/OS_HOOK_URL\/OS_HOOK_CLIENT_ID\/OS_HOOK_CLIENT_SECRET not set/, @out.string)
    assert_empty @err.string
  end

  def test_request_posts_automation_name_version_and_thread
    a = ai_notes
    captured = nil
    a.define_singleton_method(:post_json) { |body| captured = body and true }

    assert a.request(version: "2.1.0", slack: { channel: "C0APP", ts: "1700000000.000100" })
    assert_equal(
      { automation: "release-notes",
        params: { version: "2.1.0", slack: { channel: "C0APP", thread_ts: "1700000000.000100" } } },
      captured
    )
  end

  def test_request_omits_slack_when_no_anchor
    a = ai_notes
    captured = nil
    a.define_singleton_method(:post_json) { |body| captured = body and true }

    assert a.request(version: "2.1.0", slack: nil)
    assert_equal({ automation: "release-notes", params: { version: "2.1.0" } }, captured)
  end

  def test_request_warns_and_returns_false_on_failure
    a = ai_notes
    a.define_singleton_method(:post_json) { |_body| raise Errno::ECONNREFUSED }

    refute a.request(version: "2.1.0")
    assert_match(/warning: AI notes request failed/, @err.string)
  end
end
