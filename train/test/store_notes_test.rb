# frozen_string_literal: true

require_relative "test_helper"
require "train/store_notes"

class StoreNotesTest < Minitest::Test
  def render(markdown)
    Train::StoreNotes.render(markdown)
  end

  def test_seeded_notes_shape_renders_store_ready
    md = <<~MD
      ## Features
      - Add group invites (#123)

      ## Fixes
      - **Crash** on cold launch
    MD

    assert_equal <<~TXT.strip, render(md)
      Features:
      • Add group invites (#123)

      Fixes:
      • Crash on cold launch
    TXT
  end

  def test_links_reduce_to_their_text
    assert_equal "See the changelog for details", render("See [the changelog](https://example.com/log) for details")
  end

  def test_reviewer_rendering_keeps_urls
    out = Train::StoreNotes.render_reviewer("Login at [staging](https://test.convos.org), creds in 1Password")
    assert_equal "Login at staging (https://test.convos.org), creds in 1Password", out
  end

  def test_reviewer_rendering_shares_the_listing_typography
    out = Train::StoreNotes.render_reviewer("## Test accounts\n- **user**: qa@convos.org\n")
    assert_equal "Test accounts:\n• user: qa@convos.org", out
  end

  def test_emphasis_and_code_are_stripped
    assert_equal "really fast sync", render("**really** *fast* `sync`")
  end

  def test_header_trailing_colon_not_doubled
    assert_equal "Fixes:", render("## Fixes:")
  end

  def test_blank_line_runs_collapse
    assert_equal "one\n\ntwo", render("one\n\n\n\n\ntwo")
  end

  def test_empty_and_nil_render_empty
    assert_equal "", render("")
    assert_equal "", render(nil)
  end

  # GitHub renders these fine, the stores must not see the markup.

  def test_inline_html_tags_are_stripped_keeping_text
    assert_equal "Tap Enter to send bold messages", render("Tap <kbd>Enter</kbd> to send <b>bold</b> messages")
  end

  def test_block_html_is_stripped_keeping_text
    assert_equal "centered note", render("<div>\ncentered note\n</div>")
  end

  def test_strikethrough_is_stripped
    assert_equal "removed feature", render("~~removed~~ feature")
  end

  def test_entities_decode
    assert_equal "Fish & chips < more", render("Fish &amp; chips &lt; more")
  end

  def test_tables_render_without_pipes
    md = "| Col A | Col B |\n|---|---|\n| one | two |\n"
    out = render(md)
    refute_includes out, "|"
    assert_includes out, "one"
  end

  def test_invalid_bytes_are_scrubbed_not_raised
    bad = "ok \xFF text".dup.force_encoding(Encoding::ASCII_8BIT)
    out = Train::StoreNotes.render(bad)
    assert_includes out, "ok"
    assert_includes out, "text"
  end
end
