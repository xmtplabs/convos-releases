# frozen_string_literal: true

require "redcarpet"
require "redcarpet/render_strip"

module Train
  # Renders release-notes markdown into store-ready plain text — neither
  # store renders markup. Headers become "Header:" lines, list items get
  # real bullets, links reduce to their text, emphasis is stripped.
  module StoreNotes
    PLAY_LIMIT = 500

    class StoreText < Redcarpet::Render::StripDown
      def header(text, _level)
        "#{text.sub(/:\s*\z/, "")}:\n"
      end

      def list_item(text, _list_type)
        "• #{text.strip}\n"
      end

      def link(_link, _title, content)
        content
      end

      def paragraph(text)
        "#{text}\n\n"
      end
    end

    module_function

    # Output is always UTF-8 (the bullets are), independent of the process
    # locale a caller read the markdown under.
    def render(markdown)
      text = markdown.to_s
      text = text.dup.force_encoding(Encoding::UTF_8) unless text.encoding == Encoding::UTF_8

      Redcarpet::Markdown.new(StoreText.new)
                         .render(text)
                         .gsub(/\n{3,}/, "\n\n")
                         .strip
    end
  end
end
