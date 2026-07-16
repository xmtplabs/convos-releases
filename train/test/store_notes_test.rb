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
end
