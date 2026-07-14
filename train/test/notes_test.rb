# frozen_string_literal: true

require_relative "test_helper"
require "train/notes"

class NotesTest < Minitest::Test
  def pr(number:, title:, bot: false)
    { "number" => number, "title" => title, "author" => { "is_bot" => bot } }
  end

  def test_groups_features_fixes_other
    prs = [
      pr(number: 1, title: "feat: add dark mode"),
      pr(number: 2, title: "fix: crash on launch"),
      pr(number: 3, title: "chore: bump deps"),
      pr(number: 4, title: "Fix: capitalized fix prefix"),
      pr(number: 5, title: "Feat: capitalized feat prefix")
    ]
    out = Train::Notes.format(prs)

    assert_match(/## Features\n- feat: add dark mode \(#1\)\n- Feat: capitalized feat prefix \(#5\)/, out)
    assert_match(/## Fixes\n- fix: crash on launch \(#2\)\n- Fix: capitalized fix prefix \(#4\)/, out)
    assert_match(/## Other\n- chore: bump deps \(#3\)/, out)
  end

  def test_filters_bot_authors_only
    prs = [
      pr(number: 1, title: "feat: real feature", bot: false),
      pr(number: 2, title: "feat: bot-authored bump", bot: true)
    ]
    out = Train::Notes.format(prs)

    assert_match(/real feature/, out)
    refute_match(/bot-authored bump/, out)
  end

  def test_does_not_filter_by_label_only_bot_author
    # No label-based filtering is deliberately absent — a dependencies PR
    # can fix a user-visible crash; humans prune, automation doesn't hide.
    prs = [pr(number: 9, title: "fix: dependencies bump fixes crash", bot: false)]
    out = Train::Notes.format(prs)
    assert_match(/dependencies bump fixes crash/, out)
  end

  def test_section_omitted_when_empty
    prs = [pr(number: 1, title: "feat: only a feature")]
    out = Train::Notes.format(prs)

    assert_match(/## Features/, out)
    refute_match(/## Fixes/, out)
    refute_match(/## Other/, out)
  end

  def test_empty_prs_yields_empty_string
    assert_equal "", Train::Notes.format([])
  end

  def test_default_since_is_seven_days_ago
    expected = (Date.today - 7).iso8601
    assert_equal expected, Train::Notes.default_since
  end
end
